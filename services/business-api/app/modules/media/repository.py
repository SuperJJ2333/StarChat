"""Persistence primitives for the Media Platform (Phase 4.1).

The repository owns three invariants and nothing else:

1. **The server computes the authoritative digest.** A client claim is verified, then
   discarded; the stored digest always comes from the bytes this process received.
2. **Isolation is enforced before any write.** ``owner_scope``/``isolation_domain`` are
   derived from the digest kind, never accepted from the caller.
3. **Blob sharing never crosses isolation domains.** A digest lookup is always scoped by
   ``(isolation_domain, digest...)`` and by the object reuse rule below.

Object reuse rule (the frozen middle ground between ADR-001 and ADR-0060):

* an **E2EE** upload whose ciphertext is ``dedup_eligible`` reuses the existing object, so
  the same ciphertext stays a single ``media_id`` across users (the shipped behaviour);
* a **plaintext** upload always gets its own object row and shares only the **blob**, so
  two logical media never merge and per-user isolation holds.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any

from sqlalchemy import func, select

from app.core.errors import AppError
from app.modules.media.domain import (
    MEDIA_KIND_MAX_BYTES,
    BlobStatus,
    Digest,
    DigestKind,
    EnvelopeMode,
    IsolationDomain,
    MediaKind,
    MediaStatus,
    VariantKind,
    VariantStatus,
    VisibilityTier,
    assert_object_domain,
    ciphertext_digest,
    dedup_eligible,
    digest_of,
    new_blob_id,
    new_media_id,
    new_variant_id,
    owner_scope_key,
    plaintext_digest,
)
from app.modules.media.metrics import media_platform_metrics
from app.modules.media.models import MediaBlob, MediaObject, MediaVariant as MediaVariantRow
from app.modules.media.policy import DedupDecision, MediaDedupPolicy
from app.modules.media.storage import (
    BlobBackend,
    key_belongs_to_domain,
    storage_key_for,
)


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def as_utc(value: datetime | None) -> datetime | None:
    """SQLite returns naive datetimes; comparisons must not explode on that."""

    if value is None:
        return None
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


@dataclass(frozen=True, slots=True)
class IngestRequest:
    owner_id: str
    origin_domain: str
    kind: MediaKind
    mime: str
    content: bytes
    digest_kind: DigestKind
    envelope_mode: EnvelopeMode = EnvelopeMode.NONE
    visibility: VisibilityTier = VisibilityTier.PRIVATE
    metadata: dict[str, Any] | None = None
    width: int | None = None
    height: int | None = None
    duration_ms: int | None = None
    digest_version: int = 1
    envelope_version: int = 1
    #: Optional client claim. Verified for transport digests only; never authoritative.
    transport_claim: Digest | None = None
    max_bytes: int | None = None
    #: Optional legacy-recognised prefix (e.g. `moments`) kept out of the domain address.
    key_namespace: str | None = None


@dataclass(frozen=True, slots=True)
class IngestResult:
    media_id: str
    blob_id: str
    variant_id: str
    digest_kind: DigestKind
    digest_value: str
    size: int
    reused_object: bool
    reused_blob: bool


class MediaRepository:
    def __init__(
        self,
        session_factory,
        *,
        backend: BlobBackend,
        dedup_policy: MediaDedupPolicy | None = None,
        now_factory=utcnow,
    ) -> None:
        self._session_factory = session_factory
        self._backend = backend
        self._dedup = dedup_policy or MediaDedupPolicy()
        self._now = now_factory

    @property
    def session_factory(self):
        return self._session_factory

    @property
    def backend(self) -> BlobBackend:
        return self._backend

    # ------------------------------------------------------------------ #
    # Ingest
    # ------------------------------------------------------------------ #
    def ingest(self, request: IngestRequest) -> IngestResult:
        if not request.content:
            raise AppError(
                code="MEDIA_CONTENT_REQUIRED",
                message="媒体内容为空",
                status_code=422,
            )
        limit = request.max_bytes or MEDIA_KIND_MAX_BYTES[request.kind]
        if len(request.content) > limit:
            raise AppError(
                code="MEDIA_TOO_LARGE",
                message="媒体超过大小限制",
                status_code=413,
            )

        digest = self._authoritative_digest(request)
        domain = assert_object_domain(
            digest.kind, owner_scope_key(self._domain_for(digest.kind), request.owner_id)
        )
        scope_key = owner_scope_key(domain, request.owner_id)
        # ``dedup_eligible`` is the frozen ADR-002 predicate: "these bytes may be reused
        # *across users*". It is deliberately independent of the policy decision below,
        # because the policy also answers the narrower question "should we even look for a
        # reusable row inside this isolation domain?".
        cross_user_eligible = dedup_eligible(
            digest_kind=digest.kind,
            envelope_mode=request.envelope_mode,
            size=len(request.content),
            min_size_bytes=self._dedup.min_dedup_bytes,
        )
        reuse_attempt = (
            self._dedup.decide(
                digest_kind=digest.kind,
                envelope_mode=request.envelope_mode,
                envelope_version=request.envelope_version,
                size=len(request.content),
            )
            is DedupDecision.REUSE
        )

        now = self._now()
        with self._session_factory.begin() as session:
            existing_blob = (
                self._find_blob(
                    session,
                    domain=domain,
                    scope_key=scope_key,
                    digest=digest,
                    envelope_version=request.envelope_version,
                )
                if reuse_attempt
                else None
            )
            reusable_object = (
                existing_blob is not None
                and cross_user_eligible
                and digest.kind is DigestKind.CIPHERTEXT
            )
            if reusable_object:
                media = session.get(MediaObject, existing_blob.object_id) if existing_blob.object_id else None
                if media is not None and media.status != MediaStatus.DELETED.value:
                    variant = self._primary_variant(session, media.media_id)
                    if variant is not None:
                        media_platform_metrics.increment("object_reused")
                        return IngestResult(
                            media_id=media.media_id,
                            blob_id=existing_blob.blob_id,
                            variant_id=variant.variant_id,
                            digest_kind=digest.kind,
                            digest_value=digest.value,
                            size=existing_blob.size,
                            reused_object=True,
                            reused_blob=True,
                        )

            if existing_blob is None:
                blob = self._write_blob(
                    session,
                    request=request,
                    digest=digest,
                    domain=domain,
                    scope_key=scope_key,
                    eligible=cross_user_eligible,
                    now=now,
                )
                reused_blob = False
            else:
                blob = existing_blob
                reused_blob = True

            media = MediaObject(
                media_id=new_media_id(),
                owner_id=request.owner_id,
                owner_scope=scope_key,
                isolation_domain=domain.value,
                origin_domain=request.origin_domain,
                kind=request.kind.value,
                canonical_mime=request.mime,
                canonical_size=len(request.content),
                width=request.width,
                height=request.height,
                duration_ms=request.duration_ms,
                digest_kind=digest.kind.value,
                digest_version=digest.version,
                content_digest=digest.value,
                envelope_mode=request.envelope_mode.value,
                envelope_version=request.envelope_version,
                dedup_eligible=cross_user_eligible,
                status=MediaStatus.ACTIVE.value,
                visibility_hint=request.visibility.value,
                ref_count=0,
                metadata_json=request.metadata or None,
                created_at=now,
                ready_at=now,
                # A brand new object is unreferenced; the grace period protects it until a
                # reference is attached (ADR-006).
                unreferenced_at=now,
            )
            session.add(media)

            variant = MediaVariantRow(
                variant_id=new_variant_id(),
                media_id=media.media_id,
                kind=VariantKind.ORIGINAL.value,
                blob_id=blob.blob_id,
                status=VariantStatus.READY.value,
                mime=request.mime,
                width=request.width,
                height=request.height,
                duration_ms=request.duration_ms,
                size=len(request.content),
                generation=1,
                derived_from=None,
                is_primary=True,
                created_at=now,
                ready_at=now,
            )
            session.add(variant)
            if blob.object_id is None:
                blob.object_id = media.media_id

            media_platform_metrics.increment("object_created")
            return IngestResult(
                media_id=media.media_id,
                blob_id=blob.blob_id,
                variant_id=variant.variant_id,
                digest_kind=digest.kind,
                digest_value=digest.value,
                size=len(request.content),
                reused_object=False,
                reused_blob=reused_blob,
            )

    # ------------------------------------------------------------------ #
    # Reads
    # ------------------------------------------------------------------ #
    def get_object(self, media_id: str) -> MediaObject | None:
        with self._session_factory() as session:
            return session.get(MediaObject, media_id)

    def get_blob(self, blob_id: str) -> MediaBlob | None:
        with self._session_factory() as session:
            return session.get(MediaBlob, blob_id)

    def list_variants(self, media_id: str) -> list[MediaVariantRow]:
        with self._session_factory() as session:
            return list(
                session.scalars(
                    select(MediaVariantRow)
                    .where(MediaVariantRow.media_id == media_id)
                    .order_by(MediaVariantRow.generation.desc(), MediaVariantRow.created_at.asc())
                )
            )

    def find_variant(self, media_id: str, kind: VariantKind) -> MediaVariantRow | None:
        with self._session_factory() as session:
            return session.scalars(
                select(MediaVariantRow)
                .where(
                    MediaVariantRow.media_id == media_id,
                    MediaVariantRow.kind == kind.value,
                    MediaVariantRow.status == VariantStatus.READY.value,
                )
                .order_by(MediaVariantRow.generation.desc())
                .limit(1)
            ).first()

    def read_bytes(self, blob: MediaBlob) -> bytes:
        media_platform_metrics.increment("blob_read")
        with media_platform_metrics.timed("storage_read_ms"):
            return self._backend.get(blob.storage_key)

    def touch(self, media_id: str) -> None:
        """Access bookkeeping.

        Kept as a single narrow update; callers batch it (the API updates at most once per
        request) so a read never becomes an unbounded write amplification.
        """

        now = self._now()
        with self._session_factory.begin() as session:
            media = session.get(MediaObject, media_id)
            if media is None:
                return
            media.last_access_at = now

    # ------------------------------------------------------------------ #
    # Lifecycle primitives (used by the collector in Phase 4.6)
    # ------------------------------------------------------------------ #
    def set_status(self, media_id: str, status: MediaStatus, *, reason: str | None = None) -> None:
        now = self._now()
        with self._session_factory.begin() as session:
            media = session.get(MediaObject, media_id)
            if media is None:
                return
            media.status = status.value
            if status is MediaStatus.ORPHAN:
                media.unreferenced_at = media.unreferenced_at or now
            elif status is MediaStatus.DELETING:
                media.deleting_at = now
            elif status is MediaStatus.DELETED:
                media.deleted_at = now
                media.quarantine_reason = media.quarantine_reason or reason
        if status is MediaStatus.DELETED:
            for blob in self._blobs_for(media_id):
                self._delete_blob(blob.blob_id)

    def recompute_ref_count(self, media_id: str) -> int:
        """Reference counts are a cache; the reference table is the truth (ADR-006)."""

        from app.modules.media.models import MediaReference

        now = self._now()
        with self._session_factory.begin() as session:
            count = session.scalar(
                select(func.count())
                .select_from(MediaReference)
                .where(
                    MediaReference.media_id == media_id,
                    MediaReference.state == "active",
                )
            )
            media = session.get(MediaObject, media_id)
            if media is None:
                return 0
            previous = media.ref_count
            media.ref_count = int(count or 0)
            if media.ref_count > 0:
                media.status = MediaStatus.ACTIVE.value
                media.unreferenced_at = None
            elif previous > 0:
                media.status = MediaStatus.ORPHAN.value
                media.unreferenced_at = media.unreferenced_at or now
            return media.ref_count

    # ------------------------------------------------------------------ #
    # Internals
    # ------------------------------------------------------------------ #
    def _authoritative_digest(self, request: IngestRequest) -> Digest:
        if request.transport_claim is not None:
            from app.modules.media.domain import assert_transport_claim_matches

            assert_transport_claim_matches(request.transport_claim, request.content)
        if request.digest_kind is DigestKind.PLAINTEXT:
            return plaintext_digest(request.content, version=request.digest_version)
        if request.digest_kind is DigestKind.CIPHERTEXT:
            return ciphertext_digest(request.content, version=request.digest_version)
        if request.digest_kind is DigestKind.TRANSPORT:
            # A transport digest is a claim about transport, never an object identity.
            raise AppError(
                code="MEDIA_DIGEST_KIND_INVALID",
                message="传输摘要不能作为媒体身份",
                status_code=422,
            )
        return digest_of(request.digest_kind, request.content, version=request.digest_version)

    @staticmethod
    def _domain_for(digest_kind: DigestKind) -> IsolationDomain:
        from app.modules.media.domain import isolation_domain_for

        return isolation_domain_for(digest_kind)

    def _find_blob(
        self,
        session,
        *,
        domain: IsolationDomain,
        scope_key: str,
        digest: Digest,
        envelope_version: int,
    ) -> MediaBlob | None:
        """Look up reusable bytes **inside one isolation domain only**.

        * E2EE (shared scope): reuse is allowed across users, so the row must be
          ``dedup_eligible`` (deterministic envelope above the threshold).
        * user (per-owner scope): reuse is confined to this owner by the ``owner_scope``
          filter. ``dedup_eligible`` stays ``False`` here, because that flag means
          "cross-user reuse allowed" and per-owner reuse must never be mistaken for it.
        """

        conditions = [
            MediaBlob.isolation_domain == domain.value,
            MediaBlob.digest_kind == digest.kind.value,
            MediaBlob.digest_version == digest.version,
            MediaBlob.envelope_version == envelope_version,
            MediaBlob.content_digest == digest.value,
            MediaBlob.status != BlobStatus.DELETED.value,
        ]
        if domain is IsolationDomain.USER:
            conditions.append(MediaBlob.owner_scope == scope_key)
        else:
            conditions.append(MediaBlob.dedup_eligible.is_(True))
        return session.scalars(select(MediaBlob).where(*conditions).limit(1)).first()

    def _write_blob(
        self,
        session,
        *,
        request: IngestRequest,
        digest: Digest,
        domain: IsolationDomain,
        scope_key: str,
        eligible: bool,
        now: datetime,
    ) -> MediaBlob:
        blob_id = new_blob_id()
        key = storage_key_for(
            isolation_domain=domain,
            scope_key=scope_key,
            blob_id=blob_id,
            mime=request.mime,
            kind=request.kind,
            namespace=request.key_namespace,
        )
        if not key_belongs_to_domain(key, digest_kind=digest.kind, owner_scope=scope_key):
            raise AppError(
                code="MEDIA_STORAGE_KEY_INVALID",
                message="媒体存储引用无效",
                status_code=500,
            )
        self._backend.put(key, request.content)
        media_platform_metrics.increment("blob_written")
        blob = MediaBlob(
            blob_id=blob_id,
            object_id=None,
            owner_id=request.owner_id,
            owner_scope=scope_key,
            isolation_domain=domain.value,
            digest_kind=digest.kind.value,
            digest_version=digest.version,
            content_digest=digest.value,
            size=len(request.content),
            mime=request.mime,
            storage_backend="local_private",
            storage_key=key,
            envelope_mode=request.envelope_mode.value,
            envelope_version=request.envelope_version,
            dedup_eligible=eligible,
            status=BlobStatus.VERIFIED.value,
            created_at=now,
            verified_at=now,
        )
        session.add(blob)
        return blob

    def _primary_variant(self, session, media_id: str) -> MediaVariantRow | None:
        return session.scalars(
            select(MediaVariantRow)
            .where(
                MediaVariantRow.media_id == media_id,
                MediaVariantRow.status == VariantStatus.READY.value,
            )
            .order_by(MediaVariantRow.generation.desc(), MediaVariantRow.created_at.asc())
            .limit(1)
        ).first()

    def _blobs_for(self, media_id: str) -> list[MediaBlob]:
        with self._session_factory() as session:
            return list(
                session.scalars(
                    select(MediaBlob).where(
                        MediaBlob.object_id == media_id,
                        MediaBlob.status != BlobStatus.DELETED.value,
                    )
                )
            )

    def _delete_blob(self, blob_id: str) -> None:
        now = self._now()
        with self._session_factory.begin() as session:
            blob = session.get(MediaBlob, blob_id)
            if blob is None or blob.status == BlobStatus.DELETED.value:
                return
            blob.status = BlobStatus.RETIRING.value
            blob.retiring_at = now
            key = blob.storage_key
        # Mark before unlink: a crash between the two leaves a recoverable RETIRING row
        # rather than a missing file nobody knows about.
        self._backend.delete(key)
        with self._session_factory.begin() as session:
            blob = session.get(MediaBlob, blob_id)
            if blob is not None:
                blob.status = BlobStatus.DELETED.value
                blob.deleted_at = now


def orphan_grace_deadline(now: datetime, *, grace_seconds: int) -> datetime:
    return now - timedelta(seconds=grace_seconds)
