"""Reference system (Phase 4.3). Business objects point at media, never own bytes.

Frozen rules implemented here (`docs/architecture/media-engine-phase3-freeze.md` §4.6):

* a reference is the only way a business object relates to media, and releasing it is the
  only way deletion starts (``Remove Reference → Check References → Mark Orphan → GC``);
* ``(media_id, business_type, business_id)`` is unique while ``active``, so re-attaching is
  idempotent and a released row stays for audit;
* ``ref_count`` is a cache; the reference table is the truth and is always recomputed;
* a ``declared`` reference is advisory: it can never be the only reason bytes are kept
  alive *or* the only reason they are deleted — deletion is decided by the collector from
  the recomputed count plus the retention floor.

Isolation rule for attaching (ADR-001): in the per-owner plaintext domain only the object
owner may reference it, so no user can pull another user's plaintext into their business
object. In the shared E2EE domain every uploader keeps an independent reference to the same
ciphertext, which is exactly the shipped ADR-0060 behaviour.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from app.core.errors import AppError
from app.modules.media.domain import (
    BusinessType,
    DigestKind,
    IsolationDomain,
    MediaStatus,
    ReferenceKind,
    ReferenceState,
    ReleaseReason,
    VisibilityTier,
    new_reference_id,
)
from app.modules.media.metrics import media_platform_metrics
from app.modules.media.models import MediaObject, MediaReference
from app.modules.media.repository import utcnow


#: Markers of the ``uq_media_references_active`` partial unique index. PostgreSQL names the
#: constraint and SQLite names the columns, so both spellings are recognised.
ACTIVE_REFERENCE_CONFLICT_MARKERS = (
    "uq_media_references_active",
    "media_references.media_id",
)


def is_active_reference_conflict(error: BaseException) -> bool:
    """True when the database refused a second *active* reference for one business object."""

    text = str(getattr(error, "orig", error))
    return any(marker in text for marker in ACTIVE_REFERENCE_CONFLICT_MARKERS)


@dataclass(frozen=True, slots=True)
class ReferenceView:
    reference_id: str
    media_id: str
    owner_id: str
    business_type: str
    business_id: str
    variant_kind: str | None
    room_ref: str | None
    permission_scope: str
    ref_kind: str
    state: str
    created_at: str
    released_at: str | None
    release_reason: str | None

    @staticmethod
    def of(row: MediaReference) -> "ReferenceView":
        return ReferenceView(
            reference_id=row.reference_id,
            media_id=row.media_id,
            owner_id=row.owner_id,
            business_type=row.business_type,
            business_id=row.business_id,
            variant_kind=row.variant_kind,
            room_ref=row.room_ref,
            permission_scope=row.permission_scope,
            ref_kind=row.ref_kind,
            state=row.state,
            created_at=row.created_at.isoformat(),
            released_at=row.released_at.isoformat() if row.released_at else None,
            release_reason=row.release_reason,
        )


class MediaReferenceService:
    def __init__(self, session_factory, *, now_factory=utcnow) -> None:
        self._session_factory = session_factory
        self._now = now_factory

    # ------------------------------------------------------------------ #
    # Attach / release
    # ------------------------------------------------------------------ #
    def attach(
        self,
        *,
        media_id: str,
        actor_id: str,
        business_type: BusinessType,
        business_id: str,
        variant_kind: str | None = None,
        room_ref: str | None = None,
        permission_scope: VisibilityTier = VisibilityTier.PRIVATE,
        ref_kind: ReferenceKind = ReferenceKind.OBSERVED,
    ) -> ReferenceView:
        if not business_id:
            raise AppError(
                code="MEDIA_REFERENCE_INVALID",
                message="业务引用不合法",
                status_code=422,
            )
        try:
            return self._attach(
                media_id=media_id,
                actor_id=actor_id,
                business_type=business_type,
                business_id=business_id,
                variant_kind=variant_kind,
                room_ref=room_ref,
                permission_scope=permission_scope,
                ref_kind=ref_kind,
            )
        except IntegrityError as error:
            if not is_active_reference_conflict(error):
                raise
            # Two requests attached the same business object at the same time and the other
            # one won the partial unique index. That is the same outcome this call wanted,
            # so return the winner's row instead of failing the request.
            winner = self._active_reference(
                media_id=media_id,
                business_type=business_type,
                business_id=business_id,
            )
            if winner is None:
                raise
            media_platform_metrics.increment("reference_attach_race_reused")
            return winner

    def _active_reference(
        self,
        *,
        media_id: str,
        business_type: BusinessType,
        business_id: str,
    ) -> ReferenceView | None:
        with self._session_factory() as session:
            row = self._find_active_reference(
                session,
                media_id=media_id,
                business_type=business_type,
                business_id=business_id,
            )
            if row is None:
                return None
            return ReferenceView.of(row)

    @staticmethod
    def _find_active_reference(
        session,
        *,
        media_id: str,
        business_type: BusinessType,
        business_id: str,
    ) -> MediaReference | None:
        return session.scalars(
            select(MediaReference).where(
                MediaReference.media_id == media_id,
                MediaReference.business_type == business_type.value,
                MediaReference.business_id == business_id,
                MediaReference.state == ReferenceState.ACTIVE.value,
            )
        ).first()

    def _attach(
        self,
        *,
        media_id: str,
        actor_id: str,
        business_type: BusinessType,
        business_id: str,
        variant_kind: str | None,
        room_ref: str | None,
        permission_scope: VisibilityTier,
        ref_kind: ReferenceKind,
    ) -> ReferenceView:
        now = self._now()
        with self._session_factory.begin() as session:
            media = session.get(MediaObject, media_id)
            if media is None or media.status == MediaStatus.DELETED.value:
                raise AppError(
                    code="MEDIA_OBJECT_NOT_FOUND",
                    message="媒体不存在",
                    status_code=404,
                )
            self._assert_may_reference(media=media, actor_id=actor_id)

            existing = self._find_active_reference(
                session,
                media_id=media_id,
                business_type=business_type,
                business_id=business_id,
            )
            if existing is not None:
                existing.variant_kind = variant_kind or existing.variant_kind
                existing.room_ref = room_ref or existing.room_ref
                existing.permission_scope = permission_scope.value
                return ReferenceView.of(existing)

            row = MediaReference(
                reference_id=new_reference_id(),
                media_id=media_id,
                owner_id=actor_id,
                variant_kind=variant_kind,
                business_type=business_type.value,
                business_id=business_id,
                room_ref=room_ref,
                permission_scope=permission_scope.value,
                ref_kind=ref_kind.value,
                state=ReferenceState.ACTIVE.value,
                created_at=now,
            )
            session.add(row)
            session.flush()
            self._recount_in_session(session, media, now)
            media_platform_metrics.increment("reference_attached")
            return ReferenceView.of(row)

    def release(
        self,
        *,
        reference_id: str,
        actor_id: str,
        reason: ReleaseReason = ReleaseReason.USER_DELETE,
    ) -> ReferenceView:
        now = self._now()
        with self._session_factory.begin() as session:
            row = session.get(MediaReference, reference_id)
            if row is None:
                raise AppError(
                    code="MEDIA_REFERENCE_NOT_FOUND",
                    message="媒体引用不存在",
                    status_code=404,
                )
            media = session.get(MediaObject, row.media_id)
            if media is None:
                raise AppError(
                    code="MEDIA_OBJECT_NOT_FOUND",
                    message="媒体不存在",
                    status_code=404,
                )
            self._assert_may_reference(media=media, actor_id=actor_id, releasing_owner=row.owner_id)
            if row.state == ReferenceState.ACTIVE.value:
                row.state = ReferenceState.RELEASED.value
                row.released_at = now
                row.release_reason = reason.value
                session.flush()
                self._recount_in_session(session, media, now)
                media_platform_metrics.increment("reference_released")
            return ReferenceView.of(row)

    def release_for_business(
        self,
        *,
        business_type: BusinessType,
        business_id: str,
        reason: ReleaseReason,
        actor_id: str | None = None,
    ) -> list[ReferenceView]:
        """Release every active reference of a business object (e.g. a deleted moment)."""

        now = self._now()
        released: list[ReferenceView] = []
        with self._session_factory.begin() as session:
            rows = list(
                session.scalars(
                    select(MediaReference).where(
                        MediaReference.business_type == business_type.value,
                        MediaReference.business_id == business_id,
                        MediaReference.state == ReferenceState.ACTIVE.value,
                    )
                )
            )
            touched: dict[str, MediaObject] = {}
            for row in rows:
                if actor_id is not None and row.owner_id != actor_id:
                    # Another user's reference is never released by proxy.
                    continue
                row.state = ReferenceState.RELEASED.value
                row.released_at = now
                row.release_reason = reason.value
                media = touched.get(row.media_id) or session.get(MediaObject, row.media_id)
                if media is not None:
                    touched[row.media_id] = media
                released.append(ReferenceView.of(row))
            session.flush()
            for media in touched.values():
                self._recount_in_session(session, media, now)
        if released:
            media_platform_metrics.increment("reference_released", len(released))
        return released

    # ------------------------------------------------------------------ #
    # Reads
    # ------------------------------------------------------------------ #
    def list_for_media(self, media_id: str, *, include_released: bool = False) -> list[ReferenceView]:
        with self._session_factory() as session:
            statement = select(MediaReference).where(MediaReference.media_id == media_id)
            if not include_released:
                statement = statement.where(
                    MediaReference.state == ReferenceState.ACTIVE.value
                )
            return [
                ReferenceView.of(row)
                for row in session.scalars(statement.order_by(MediaReference.created_at))
            ]

    def list_for_business(
        self, *, business_type: BusinessType, business_id: str
    ) -> list[ReferenceView]:
        with self._session_factory() as session:
            return [
                ReferenceView.of(row)
                for row in session.scalars(
                    select(MediaReference).where(
                        MediaReference.business_type == business_type.value,
                        MediaReference.business_id == business_id,
                        MediaReference.state == ReferenceState.ACTIVE.value,
                    )
                )
            ]

    def recount(self, media_id: str) -> int:
        now = self._now()
        with self._session_factory.begin() as session:
            media = session.get(MediaObject, media_id)
            if media is None:
                return 0
            count = self._recount_in_session(session, media, now)
            return count

    # ------------------------------------------------------------------ #
    # Internals
    # ------------------------------------------------------------------ #
    @staticmethod
    def _assert_may_reference(
        *,
        media: MediaObject,
        actor_id: str,
        releasing_owner: str | None = None,
    ) -> None:
        if media.isolation_domain == IsolationDomain.USER.value:
            # Per-owner plaintext: only the owner may create or release references.
            if actor_id != media.owner_id:
                raise AppError(
                    code="MEDIA_ACCESS_DENIED",
                    message="无权引用该媒体",
                    status_code=403,
                )
            return
        if media.isolation_domain == IsolationDomain.E2EE.value:
            # Shared ciphertext: each uploader keeps an independent reference; a user may
            # only touch their own reference row.
            if releasing_owner is not None and releasing_owner != actor_id:
                raise AppError(
                    code="MEDIA_ACCESS_DENIED",
                    message="无权释放他人的媒体引用",
                    status_code=403,
                )
            return
        raise AppError(
            code="MEDIA_ACCESS_DENIED",
            message="无权引用该媒体",
            status_code=403,
        )

    @staticmethod
    def _recount_in_session(session, media: MediaObject, now) -> int:
        from sqlalchemy import func

        count = session.scalar(
            select(func.count())
            .select_from(MediaReference)
            .where(
                MediaReference.media_id == media.media_id,
                MediaReference.state == ReferenceState.ACTIVE.value,
            )
        )
        media.ref_count = int(count or 0)
        if media.ref_count > 0:
            media.status = MediaStatus.ACTIVE.value
            media.unreferenced_at = None
        elif media.status == MediaStatus.ACTIVE.value:
            media.status = MediaStatus.ORPHAN.value
            media.unreferenced_at = media.unreferenced_at or now
        return media.ref_count


#: Convenience re-export so callers do not need the model module for the enum values.
REFERENCE_DIGEST_KIND = DigestKind
__all__ = ["MediaReferenceService", "ReferenceView", "REFERENCE_DIGEST_KIND"]


def reference_metadata(view: ReferenceView) -> dict[str, Any]:
    """Audit payload: opaque ids and enums only, no digest, path or content."""

    return {
        "reference_id": view.reference_id,
        "media_id": view.media_id,
        "business_type": view.business_type,
        "ref_kind": view.ref_kind,
        "permission_scope": view.permission_scope,
    }
