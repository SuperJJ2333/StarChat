"""Media Platform persistence models (Phase 4.1).

Expand-only: these tables are new, nothing existing is altered, and no existing table
gains or loses a column. Frozen field names come from
`docs/architecture/media-engine-phase3-freeze.md` (§4.2.7, §4.6.1).

Two naming notes:

* ``MediaObject.metadata`` is a **column** name; the Python attribute is
  ``metadata_json`` because ``metadata`` is reserved by SQLAlchemy's declarative base.
* Physical bytes and their digest live on ``MediaBlob``; authorization and references
  only ever point at ``MediaObject``.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from sqlalchemy import (
    JSON,
    BigInteger,
    Boolean,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    String,
    UniqueConstraint,
    text,
)
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base

#: Partial-index predicates. A digest slot is only reserved by a *reusable* object, so two
#: random-envelope uploads of the same bytes (or two owners in the plaintext domain) can
#: coexist. Collected rows release the slot so the digest can be stored again later.
_DIGEST_SLOT = "dedup_eligible AND status <> 'DELETED'"
_ACTIVE_REFERENCE = "state = 'active'"
_ACTIVE_GRANT = "revoked_at IS NULL"


class MediaObject(Base):
    """Logical media: the identity that references, grants and lifecycle point at."""

    __tablename__ = "media_objects"
    __table_args__ = (
        Index(
            "uq_media_objects_digest_slot",
            "owner_scope",
            "digest_kind",
            "digest_version",
            "envelope_version",
            "content_digest",
            unique=True,
            sqlite_where=text(_DIGEST_SLOT),
            postgresql_where=text(_DIGEST_SLOT),
        ),
        Index("ix_media_objects_owner", "owner_id", "created_at"),
        Index("ix_media_objects_scope", "owner_scope", "status"),
        Index("ix_media_objects_status", "status", "unreferenced_at"),
        Index("ix_media_objects_access", "last_access_at"),
    )

    media_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    owner_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    #: Isolation domain scope key, e.g. ``user:<owner>`` / ``e2ee:ciphertext-v1``.
    owner_scope: Mapped[str] = mapped_column(String(80), nullable=False)
    isolation_domain: Mapped[str] = mapped_column(String(20), nullable=False)
    origin_domain: Mapped[str] = mapped_column(String(20), nullable=False, index=True)
    kind: Mapped[str] = mapped_column(String(16), nullable=False)

    canonical_mime: Mapped[str] = mapped_column(String(120), nullable=False)
    canonical_size: Mapped[int] = mapped_column(BigInteger, nullable=False)
    width: Mapped[int | None] = mapped_column(Integer)
    height: Mapped[int | None] = mapped_column(Integer)
    duration_ms: Mapped[int | None] = mapped_column(BigInteger)

    digest_kind: Mapped[str] = mapped_column(String(32), nullable=False)
    digest_version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    content_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    envelope_mode: Mapped[str] = mapped_column(String(24), nullable=False)
    envelope_version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    dedup_eligible: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)

    status: Mapped[str] = mapped_column(String(16), nullable=False, default="ACTIVE")
    visibility_hint: Mapped[str] = mapped_column(String(16), nullable=False, default="private")
    ref_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    #: Column name is frozen as ``metadata``; attribute avoids the SQLAlchemy reserved name.
    metadata_json: Mapped[dict[str, Any] | None] = mapped_column("metadata", JSON)

    #: Orthogonal attributes, not lifecycle states (ADR-006).
    pinned_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    quarantined_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    quarantine_reason: Mapped[str | None] = mapped_column(String(60))

    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    ready_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    unreferenced_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    last_access_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    deleting_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class MediaBlob(Base):
    """Physical bytes: digest, size, storage location and encryption envelope."""

    __tablename__ = "media_blobs"
    __table_args__ = (
        Index(
            "uq_media_blobs_digest_slot",
            "isolation_domain",
            "digest_kind",
            "digest_version",
            "envelope_version",
            "content_digest",
            unique=True,
            sqlite_where=text(_DIGEST_SLOT),
            postgresql_where=text(_DIGEST_SLOT),
        ),
        Index("ix_media_blobs_object", "object_id"),
        Index("ix_media_blobs_status", "status", "retiring_at"),
        Index("ix_media_blobs_scope", "owner_scope", "status"),
    )

    blob_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    #: First owner of the bytes (quota/audit attribution). Sharing happens via variants.
    object_id: Mapped[str | None] = mapped_column(
        String(36), ForeignKey("media_objects.media_id"), nullable=True
    )
    owner_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    owner_scope: Mapped[str] = mapped_column(String(80), nullable=False)
    isolation_domain: Mapped[str] = mapped_column(String(20), nullable=False)

    digest_kind: Mapped[str] = mapped_column(String(32), nullable=False)
    digest_version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    content_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    size: Mapped[int] = mapped_column(BigInteger, nullable=False)
    mime: Mapped[str] = mapped_column(String(120), nullable=False)

    storage_backend: Mapped[str] = mapped_column(String(24), nullable=False, default="local_private")
    storage_key: Mapped[str] = mapped_column(String(512), nullable=False, unique=True)

    envelope_mode: Mapped[str] = mapped_column(String(24), nullable=False, default="none")
    envelope_version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    dedup_eligible: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)

    status: Mapped[str] = mapped_column(String(16), nullable=False, default="STAGED")
    pinned_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    retiring_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class MediaVariant(Base):
    """A rendition of an object: encoding metadata plus a pointer to the bytes."""

    __tablename__ = "media_variants"
    __table_args__ = (
        UniqueConstraint("media_id", "kind", "generation", name="uq_media_variants_kind"),
        Index("ix_media_variants_ready", "media_id", "kind", "status"),
        Index("ix_media_variants_blob", "blob_id"),
        Index("ix_media_variants_queue", "status", "created_at"),
    )

    variant_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    media_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("media_objects.media_id"), nullable=False, index=True
    )
    kind: Mapped[str] = mapped_column(String(24), nullable=False)
    blob_id: Mapped[str | None] = mapped_column(
        String(36), ForeignKey("media_blobs.blob_id"), nullable=True
    )
    status: Mapped[str] = mapped_column(String(16), nullable=False, default="pending")

    mime: Mapped[str | None] = mapped_column(String(120))
    codec: Mapped[str | None] = mapped_column(String(40))
    width: Mapped[int | None] = mapped_column(Integer)
    height: Mapped[int | None] = mapped_column(Integer)
    duration_ms: Mapped[int | None] = mapped_column(BigInteger)
    bitrate_bps: Mapped[int | None] = mapped_column(Integer)
    size: Mapped[int | None] = mapped_column(BigInteger)

    generation: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    derived_from: Mapped[str | None] = mapped_column(String(24))
    is_primary: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    failure_reason: Mapped[str | None] = mapped_column(String(40))

    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    ready_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class MediaReference(Base):
    """Business object → media object. Deleting a business object releases a reference."""

    __tablename__ = "media_references"
    __table_args__ = (
        Index(
            "uq_media_references_active",
            "media_id",
            "business_type",
            "business_id",
            unique=True,
            sqlite_where=text(_ACTIVE_REFERENCE),
            postgresql_where=text(_ACTIVE_REFERENCE),
        ),
        Index("ix_media_references_lookup", "business_type", "business_id"),
        Index("ix_media_references_media", "media_id", "state"),
        Index("ix_media_references_scope", "owner_id", "created_at"),
    )

    reference_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    media_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("media_objects.media_id"), nullable=False
    )
    owner_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    variant_kind: Mapped[str | None] = mapped_column(String(24))

    business_type: Mapped[str] = mapped_column(String(32), nullable=False)
    business_id: Mapped[str] = mapped_column(String(160), nullable=False)
    #: Optional room/audience anchor used by audience-scoped authorization.
    room_ref: Mapped[str | None] = mapped_column(String(160))
    permission_scope: Mapped[str] = mapped_column(String(16), nullable=False, default="private")

    ref_kind: Mapped[str] = mapped_column(String(16), nullable=False, default="observed")
    state: Mapped[str] = mapped_column(String(16), nullable=False, default="active")

    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    released_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    release_reason: Mapped[str | None] = mapped_column(String(32))


class MediaAccessGrant(Base):
    """Subject-scoped permission on one media object (ADR-003)."""

    __tablename__ = "media_access_grants"
    __table_args__ = (
        Index(
            "uq_media_access_grants_subject",
            "media_id",
            "subject_type",
            "subject_id",
            "permission",
            unique=True,
            sqlite_where=text(_ACTIVE_GRANT),
            postgresql_where=text(_ACTIVE_GRANT),
        ),
        Index("ix_media_access_grants_expiry", "expires_at"),
        Index("ix_media_access_grants_subject", "subject_type", "subject_id", "media_id"),
    )

    grant_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    media_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("media_objects.media_id"), nullable=False
    )
    #: ``["*"]`` or an explicit list of variant kinds.
    variant_scope: Mapped[list[str]] = mapped_column(JSON, nullable=False)
    subject_type: Mapped[str] = mapped_column(String(16), nullable=False)
    subject_id: Mapped[str] = mapped_column(String(160), nullable=False)
    permission: Mapped[str] = mapped_column(String(24), nullable=False)
    #: ``{"rule": "...", "ref": "..."}`` — authorization re-checks this live.
    derived_from: Mapped[dict[str, Any] | None] = mapped_column(JSON)

    grant_version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    single_use: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    uses: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    max_uses: Mapped[int | None] = mapped_column(Integer)

    issued_by: Mapped[str] = mapped_column(String(36), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    revoke_reason: Mapped[str | None] = mapped_column(String(60))


class MediaUploadSession(Base):
    """Upload Engine session (ADR-005). The engine is independent of the media object flow."""

    __tablename__ = "media_upload_sessions"
    __table_args__ = (
        UniqueConstraint("owner_id", "idempotency_key", name="uq_media_upload_idempotency"),
        Index("ix_media_upload_status", "status", "expires_at"),
        Index("ix_media_upload_owner", "owner_id", "created_at"),
    )

    upload_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    owner_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    origin_domain: Mapped[str] = mapped_column(String(20), nullable=False)
    kind: Mapped[str] = mapped_column(String(16), nullable=False)
    declared_size: Mapped[int] = mapped_column(BigInteger, nullable=False)
    declared_mime: Mapped[str] = mapped_column(String(120), nullable=False)

    #: Client claim, never authoritative (ADR-002 rule 3).
    digest_claim: Mapped[str | None] = mapped_column(String(64))
    digest_claim_kind: Mapped[str | None] = mapped_column(String(32))
    envelope_mode: Mapped[str] = mapped_column(String(24), nullable=False)
    envelope_version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)

    part_size: Mapped[int] = mapped_column(BigInteger, nullable=False)
    chunks: Mapped[list[dict[str, Any]]] = mapped_column(JSON, nullable=False, default=list)
    uploaded_bytes: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)

    status: Mapped[str] = mapped_column(String(16), nullable=False, default="created")
    media_id: Mapped[str | None] = mapped_column(String(36))
    idempotency_key: Mapped[str] = mapped_column(String(128), nullable=False)

    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class MediaGcRun(Base):
    """One GC pass: dry-run or enforced. Audit trail for every collection decision."""

    __tablename__ = "media_gc_runs"
    __table_args__ = (Index("ix_media_gc_runs_started", "started_at"),)

    run_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    mode: Mapped[str] = mapped_column(String(12), nullable=False)
    scope: Mapped[str] = mapped_column(String(80), nullable=False)

    scanned: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    candidates: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    collected: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    skipped_pinned: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    skipped_referenced: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    skipped_grace: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    skipped_quarantined: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    bytes_reclaimed: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    #: Opaque media ids and their skip reason; never a digest, path or business id.
    decisions: Mapped[list[dict[str, Any]]] = mapped_column(JSON, nullable=False, default=list)

    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    error_code: Mapped[str | None] = mapped_column(String(60))


#: Predicate helpers kept next to the tables so a future partial index change is local.
__all__ = [
    "MediaAccessGrant",
    "MediaBlob",
    "MediaGcRun",
    "MediaObject",
    "MediaReference",
    "MediaUploadSession",
    "MediaVariant",
]
