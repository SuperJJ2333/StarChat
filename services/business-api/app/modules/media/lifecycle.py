"""Lifecycle state machine and garbage collector (Phase 4.6, ADR-006).

``ACTIVE → ORPHAN → DELETING → DELETED`` with ``QUARANTINED`` and ``PINNED`` as orthogonal
attributes. The collector is the only component allowed to move bytes out of existence, and
it always runs the same checklist:

1. recompute the reference count from the reference table (never trust the cached column);
2. skip anything referenced, pinned, quarantined, inside the grace period, or part of an
   in-flight upload session;
3. in ``dry_run`` mode report what *would* happen and change nothing;
4. in ``enforce`` mode mark ``DELETING`` **before** unlinking, then finish and record an
   audit row — a crash in between leaves a recoverable row, never a silent data loss;
5. a later run resumes any object found in ``DELETING`` (recovery), so a failed deletion is
   never stuck forever.

The E2EE domain gets an extra retention floor because its true reference count is
unknowable to the server (ADR-006 §6.3): fewer references is not proof that nobody wants it.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta

from sqlalchemy import func, select

from app.modules.media.domain import (
    BlobStatus,
    GcMode,
    GcSkipReason,
    IsolationDomain,
    MediaStatus,
    UploadSessionStatus,
    VariantStatus,
    new_gc_run_id,
)
from app.modules.media.metrics import media_platform_metrics
from app.modules.media.models import (
    MediaBlob,
    MediaVariant,
    MediaGcRun,
    MediaObject,
    MediaReference,
    MediaUploadSession,
)
from app.modules.media.policy import MediaPlatformPolicy
from app.modules.media.repository import utcnow


@dataclass(frozen=True, slots=True)
class GcDecision:
    media_id: str
    action: str  # collect | recover | skip
    reason: str
    bytes: int = 0


@dataclass(frozen=True, slots=True)
class GcReport:
    run_id: str
    mode: str
    scope: str
    scanned: int
    candidates: int
    collected: int
    bytes_reclaimed: int
    skipped: dict[str, int] = field(default_factory=dict)
    decisions: tuple[GcDecision, ...] = ()

    @property
    def dry_run(self) -> bool:
        return self.mode == GcMode.DRY_RUN.value


class MediaGarbageCollector:
    def __init__(
        self,
        session_factory,
        *,
        backend,
        policy: MediaPlatformPolicy | None = None,
        now_factory=utcnow,
    ) -> None:
        self._session_factory = session_factory
        self._backend = backend
        self._policy = policy or MediaPlatformPolicy()
        self._now = now_factory

    # ------------------------------------------------------------------ #
    # Public entry point
    # ------------------------------------------------------------------ #
    def run(
        self,
        *,
        mode: GcMode = GcMode.DRY_RUN,
        owner_id: str | None = None,
        limit: int = 200,
    ) -> GcReport:
        now = self._now()
        scope = owner_id or "*"
        decisions: list[GcDecision] = []
        skipped: dict[str, int] = {reason.value: 0 for reason in GcSkipReason}

        with self._session_factory() as session:
            candidates = self._candidates(session, owner_id=owner_id, limit=limit)

        collected = 0
        bytes_reclaimed = 0
        for media in candidates:
            decision = self._decide(media=media, now=now)
            decisions.append(decision)
            if decision.action == "skip":
                skipped[decision.reason] = skipped.get(decision.reason, 0) + 1
                continue
            if mode is GcMode.ENFORCE:
                self._collect(media.media_id)
                collected += 1
                bytes_reclaimed += decision.bytes
            else:
                decisions[-1] = GcDecision(
                    media_id=decision.media_id,
                    action="would_collect",
                    reason=decision.reason,
                    bytes=decision.bytes,
                )
                collected += 1
                bytes_reclaimed += decision.bytes

        report = GcReport(
            run_id=new_gc_run_id(),
            mode=mode.value,
            scope=scope,
            scanned=len(candidates),
            candidates=sum(
                1 for decision in decisions if decision.action != "skip"
            ),
            collected=collected,
            bytes_reclaimed=bytes_reclaimed,
            skipped=skipped,
            decisions=tuple(decisions),
        )
        self._record(report, now=now)
        media_platform_metrics.increment("gc_run")
        if mode is GcMode.ENFORCE:
            media_platform_metrics.increment("gc_collected", collected)
            media_platform_metrics.increment("gc_bytes_reclaimed", bytes_reclaimed)
        return report

    # ------------------------------------------------------------------ #
    # Decision
    # ------------------------------------------------------------------ #
    def _decide(self, *, media: MediaObject, now: datetime) -> GcDecision:
        size = int(media.canonical_size or 0)

        if media.quarantined_at is not None:
            # Quarantined bytes stay as a digest tombstone until explicitly released.
            return GcDecision(media.media_id, "skip", GcSkipReason.QUARANTINED.value, size)

        pinned_until = media.pinned_until
        if pinned_until is not None and _as_utc(pinned_until) > now:
            return GcDecision(media.media_id, "skip", GcSkipReason.PINNED.value, size)

        if media.status == MediaStatus.DELETING.value:
            # Recovery path: a previous run marked it and did not finish.
            return GcDecision(media.media_id, "collect", "recover_deleting", size)

        if media.status not in (MediaStatus.ORPHAN.value, MediaStatus.ACTIVE.value):
            return GcDecision(media.media_id, "skip", GcSkipReason.NOT_ORPHAN.value, size)

        if self._active_references(media.media_id) > 0:
            return GcDecision(media.media_id, "skip", GcSkipReason.HAS_REFERENCES.value, size)

        if media.unreferenced_at is None:
            return GcDecision(media.media_id, "skip", GcSkipReason.NOT_ORPHAN.value, size)

        grace = self._grace_seconds(media)
        unreferenced_at = _as_utc(media.unreferenced_at)
        if unreferenced_at + timedelta(seconds=grace) > now:
            return GcDecision(media.media_id, "skip", GcSkipReason.WITHIN_GRACE.value, size)

        if self._has_active_upload(media.media_id):
            return GcDecision(media.media_id, "skip", GcSkipReason.ACTIVE_UPLOAD.value, size)

        if self._has_processing_variant(media.media_id):
            # A variant that is still being produced (poster, transcode) holds the object:
            # collecting it would leave the pipeline writing into a deleted blob.
            return GcDecision(media.media_id, "skip", GcSkipReason.VARIANT_PROCESSING.value, size)

        return GcDecision(media.media_id, "collect", "unreferenced", size)

    def _grace_seconds(self, media: MediaObject) -> int:
        if media.isolation_domain == IsolationDomain.E2EE.value:
            return max(
                self._policy.orphan_grace_seconds,
                self._policy.e2ee_retention_floor_seconds,
            )
        return self._policy.orphan_grace_seconds

    # ------------------------------------------------------------------ #
    # Persistence helpers
    # ------------------------------------------------------------------ #
    def _candidates(self, session, *, owner_id: str | None, limit: int) -> list[MediaObject]:
        statement = (
            select(MediaObject)
            .where(
                MediaObject.status.in_(
                    [
                        MediaStatus.ORPHAN.value,
                        MediaStatus.ACTIVE.value,
                        MediaStatus.DELETING.value,
                    ]
                )
            )
            .order_by(MediaObject.unreferenced_at.asc().nullsfirst())
            .limit(limit)
        )
        if owner_id:
            statement = statement.where(MediaObject.owner_id == owner_id)
        return list(session.scalars(statement))

    def _active_references(self, media_id: str) -> int:
        with self._session_factory() as session:
            return int(
                session.scalar(
                    select(func.count())
                    .select_from(MediaReference)
                    .where(
                        MediaReference.media_id == media_id,
                        MediaReference.state == "active",
                    )
                )
                or 0
            )

    def _has_active_upload(self, media_id: str) -> bool:
        with self._session_factory() as session:
            row = session.scalars(
                select(MediaUploadSession.upload_id).where(
                    MediaUploadSession.media_id == media_id,
                    MediaUploadSession.status.notin_(
                        [
                            UploadSessionStatus.COMMITTED.value,
                            UploadSessionStatus.ABORTED.value,
                            UploadSessionStatus.EXPIRED.value,
                        ]
                    ),
                )
            ).first()
            return row is not None

    def _has_processing_variant(self, media_id: str) -> bool:
        with self._session_factory() as session:
            row = session.scalars(
                select(MediaVariant.variant_id).where(
                    MediaVariant.media_id == media_id,
                    MediaVariant.status.in_(
                        [VariantStatus.PENDING.value, VariantStatus.PROCESSING.value]
                    ),
                )
            ).first()
            return row is not None

    def _collect(self, media_id: str) -> None:
        now = self._now()
        # Step 1: mark DELETING durably (crash-safe; a later run recovers it).
        with self._session_factory.begin() as session:
            media = session.get(MediaObject, media_id)
            if media is None:
                return
            media.status = MediaStatus.DELETING.value
            media.deleting_at = now

        # Step 2: retire then unlink each blob, marking before deleting so a failure is
        # visible instead of silently orphaning a file.
        with self._session_factory() as session:
            blobs = list(
                session.scalars(
                    select(MediaBlob).where(
                        MediaBlob.object_id == media_id,
                        MediaBlob.status != BlobStatus.DELETED.value,
                    )
                )
            )
        for blob in blobs:
            key = blob.storage_key
            with self._session_factory.begin() as session:
                stored = session.get(MediaBlob, blob.blob_id)
                if stored is None:
                    continue
                stored.status = BlobStatus.RETIRING.value
                stored.retiring_at = now
            self._backend.delete(key)
            with self._session_factory.begin() as session:
                stored = session.get(MediaBlob, blob.blob_id)
                if stored is not None:
                    stored.status = BlobStatus.DELETED.value
                    stored.deleted_at = now

        # Step 3: finish the object.
        with self._session_factory.begin() as session:
            media = session.get(MediaObject, media_id)
            if media is not None:
                media.status = MediaStatus.DELETED.value
                media.deleted_at = now

    def _record(self, report: GcReport, *, now: datetime) -> None:
        with self._session_factory.begin() as session:
            session.add(
                MediaGcRun(
                    run_id=report.run_id,
                    mode=report.mode,
                    scope=report.scope,
                    scanned=report.scanned,
                    candidates=report.candidates,
                    collected=report.collected,
                    skipped_pinned=report.skipped.get(GcSkipReason.PINNED.value, 0),
                    skipped_referenced=report.skipped.get(
                        GcSkipReason.HAS_REFERENCES.value, 0
                    ),
                    skipped_grace=report.skipped.get(GcSkipReason.WITHIN_GRACE.value, 0),
                    skipped_quarantined=report.skipped.get(
                        GcSkipReason.QUARANTINED.value, 0
                    ),
                    bytes_reclaimed=report.bytes_reclaimed,
                    # Opaque ids and enum reasons only: no digest, path, token or content.
                    decisions=[
                        {
                            "media_id": decision.media_id,
                            "action": decision.action,
                            "reason": decision.reason,
                        }
                        for decision in report.decisions
                    ],
                    started_at=now,
                    finished_at=self._now(),
                )
            )


def pin_object(session_factory, *, media_id: str, seconds: int, now_factory=utcnow) -> datetime:
    """Pin an object so neither quota nor GC may collect it (ADR-006 orthogonal attribute)."""

    now = now_factory()
    until = now + timedelta(seconds=max(1, seconds))
    with session_factory.begin() as session:
        media = session.get(MediaObject, media_id)
        if media is not None:
            media.pinned_until = until
    return until


def unpin_object(session_factory, *, media_id: str) -> None:
    with session_factory.begin() as session:
        media = session.get(MediaObject, media_id)
        if media is not None:
            media.pinned_until = None


def _as_utc(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=utcnow().tzinfo)
    return value
