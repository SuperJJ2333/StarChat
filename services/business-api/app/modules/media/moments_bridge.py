"""Moments integration (Phase 4.7) — the strangler bridge, built without touching Moments.

New uploads flow ``Moments → MediaGateway → MediaObject``, while every existing Moments
media path keeps working untouched. The bridge achieves that with **no change to any
existing Moments module and no schema change**:

1. the bytes are ingested into the platform (per-owner plaintext domain, server-computed
   digest, platform blob + variant + reference);
2. the *existing* ``moment_media_uploads`` table receives one row whose ``object_key`` is the
   platform blob's storage key, marked ``COMPLETED``. That table is an upload bookkeeping
   table, so inserting a row is normal operation — its schema is not modified;
3. the caller receives the same capability URL shape the Moments API already issues, so the
   unchanged publish path (`owned_key`) and read path (`read_content`) accept it, and the
   existing readers serve the platform's bytes straight from the shared object directory.

Why this is safe rather than clever:

* old media need no migration at all — nothing is rewritten, moved or re-encrypted, and the
  legacy tables keep pointing where they always did;
* a platform-managed attachment is readable through **both** paths at once, so a rollback is
  just "stop calling the new endpoint";
* the platform reference (`moment_upload`) gives the garbage collector something to count,
  which is what the legacy path never had.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import timedelta

from sqlalchemy import select

from app.core.errors import AppError
from app.modules.media.domain import (
    BusinessType,
    DigestKind,
    EnvelopeMode,
    MediaKind,
    ReferenceKind,
    VisibilityTier,
)
from app.modules.media.metrics import media_platform_metrics
from app.modules.media.models import MediaBlob
from app.modules.media.repository import utcnow
from app.modules.moments import media as moments_media

# Deployment compatibility (found by the production readiness rehearsal): the MIME→suffix map
# and the GIF container validator were added to the Moments module *after* the revision that is
# running in production. Prefer the module's own values when present so behaviour can never
# drift from Moments, and fall back to the local equivalents so the bridge also imports against
# the older deployed revision (without the fallback the whole API fails to start).
ALLOWED_IMAGE_MIME = moments_media.ALLOWED_IMAGE_MIME
MAX_IMAGE_BYTES = moments_media.MAX_IMAGE_BYTES
MomentMediaUpload = moments_media.MomentMediaUpload

_FALLBACK_IMAGE_SUFFIX_BY_MIME = {
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/webp": ".webp",
    "image/gif": ".gif",
}
IMAGE_SUFFIX_BY_MIME = getattr(
    moments_media, "IMAGE_SUFFIX_BY_MIME", _FALLBACK_IMAGE_SUFFIX_BY_MIME
)
_validate_gif_container = getattr(moments_media, "validate_gif", None)


@dataclass(frozen=True, slots=True)
class MomentsAttachment:
    media_id: str
    blob_id: str
    upload_id: str
    reference_id: str
    capability_url: str
    byte_size: int
    mime: str
    purpose: str
    reused: bool


class MomentsMediaBridge:
    """Writes new Moments media through the platform and keeps legacy readers working."""

    def __init__(self, *, service, session_factory, storage, now_factory=utcnow) -> None:
        self._service = service
        self._session_factory = session_factory
        self._storage = storage
        self._now = now_factory

    def attach(
        self,
        *,
        actor_id: str,
        file_name: str,
        mime: str,
        content: bytes,
        idempotency_key: str,
        purpose: str = "MOMENT_IMAGE",
    ) -> MomentsAttachment:
        normalized_mime = mime.strip().casefold()
        self._validate(mime=normalized_mime, content=content, purpose=purpose)

        existing = self._find_by_idempotency(actor_id=actor_id, key=idempotency_key)
        if existing is not None:
            attachment = self._describe_existing(existing)
            if attachment is not None:
                return attachment

        kind = MediaKind.GIF if normalized_mime == "image/gif" else MediaKind.IMAGE
        result = self._service.ingest(
            owner_id=actor_id,
            origin_domain="moments",
            kind=kind,
            mime=normalized_mime,
            content=content,
            digest_kind=DigestKind.PLAINTEXT,
            envelope_mode=EnvelopeMode.NONE,
            visibility=VisibilityTier.AUDIENCE,
            metadata={"source": "moments_bridge", "purpose": purpose},
            max_bytes=MAX_IMAGE_BYTES,
            # `moments/` prefix: the unchanged Moments reader resolves `media://moments/...`
            # keys and checks the upload row, so the platform writes there while keeping the
            # isolation address (`.../media/user/<scope-hash>/...`) inside the path.
            key_namespace="moments",
        )

        blob = self._service_blob(result.blob_id)
        now = self._now()
        upload_id = _new_upload_id()
        with self._session_factory.begin() as session:
            session.add(
                MomentMediaUpload(
                    id=upload_id,
                    owner_id=actor_id,
                    file_name=file_name or f"moment-{upload_id}{IMAGE_SUFFIX_BY_MIME[normalized_mime]}",
                    mime_type=normalized_mime,
                    byte_size=len(content),
                    status="COMPLETED",
                    object_key=blob.storage_key,
                    purpose=purpose,
                    idempotency_key=idempotency_key,
                    created_at=now,
                    # Completed uploads are readable indefinitely; the window only governs
                    # an unfinished session, and this one is complete by construction.
                    expires_at=now + timedelta(days=365),
                )
            )

        reference = self._service.attach_reference(
            media_id=result.media_id,
            actor_id=actor_id,
            business_type=BusinessType.MOMENT_UPLOAD,
            business_id=upload_id,
            variant_kind="original",
            permission_scope=VisibilityTier.AUDIENCE,
            ref_kind=ReferenceKind.OBSERVED,
        )
        media_platform_metrics.increment("moments_bridge_attached")
        return MomentsAttachment(
            media_id=result.media_id,
            blob_id=result.blob_id,
            upload_id=upload_id,
            reference_id=reference.reference_id,
            capability_url=self._capability_url(
                key=blob.storage_key, upload_id=upload_id, viewer=actor_id
            ),
            byte_size=len(content),
            mime=normalized_mime,
            purpose=purpose,
            reused=result.reused_blob or result.reused_object,
        )

    # ------------------------------------------------------------------ #
    # Internals
    # ------------------------------------------------------------------ #
    @staticmethod
    def _validate(*, mime: str, content: bytes, purpose: str) -> None:
        if mime not in ALLOWED_IMAGE_MIME:
            raise AppError(
                code="MOMENT_MEDIA_INVALID",
                message="仅支持20MiB以内 JPG/PNG/WebP/GIF",
                status_code=422,
            )
        if len(content) < 1 or len(content) > MAX_IMAGE_BYTES:
            raise AppError(
                code="MOMENT_MEDIA_INVALID",
                message="仅支持20MiB以内 JPG/PNG/WebP/GIF",
                status_code=422,
            )
        if content[:6] in (b"GIF87a", b"GIF89a") and mime != "image/gif":
            raise AppError(
                code="MOMENT_MEDIA_INVALID",
                message="媒体格式与声明不一致",
                status_code=422,
            )
        if mime == "image/gif" and _validate_gif_container is not None:
            # On a deployment whose Moments module predates GIF container validation this check
            # is unavailable. The running baseline's own Moments upload path has exactly the
            # same coverage, so the bridge is never weaker than production; the mime allowlist,
            # the size cap and the format-vs-declared-mime check below always apply.
            _validate_gif_container(content)
        if purpose not in ("MOMENT_IMAGE", "MOMENT_COVER"):
            raise AppError(
                code="MOMENT_MEDIA_INVALID",
                message="媒体用途不合法",
                status_code=422,
            )

    def _find_by_idempotency(self, *, actor_id: str, key: str) -> MomentMediaUpload | None:
        with self._session_factory() as session:
            return session.scalars(
                select(MomentMediaUpload).where(
                    MomentMediaUpload.owner_id == actor_id,
                    MomentMediaUpload.idempotency_key == key,
                )
            ).first()

    def _describe_existing(self, row: MomentMediaUpload) -> MomentsAttachment | None:
        """Re-derive the attachment for an idempotent retry."""

        with self._session_factory() as session:
            blob = session.scalars(
                select(MediaBlob).where(
                    MediaBlob.storage_key == row.object_key,
                    MediaBlob.owner_id == row.owner_id,
                )
            ).first()
        if blob is None:
            return None
        references = self._service.references.list_for_business(
            business_type=BusinessType.MOMENT_UPLOAD, business_id=row.id
        )
        if not references:
            return None
        return MomentsAttachment(
            media_id=references[0].media_id,
            blob_id=blob.blob_id,
            upload_id=row.id,
            reference_id=references[0].reference_id,
            capability_url=self._capability_url(
                key=row.object_key, upload_id=row.id, viewer=row.owner_id
            ),
            byte_size=row.byte_size,
            mime=row.mime_type,
            purpose=row.purpose,
            reused=True,
        )

    def _service_blob(self, blob_id: str) -> MediaBlob:
        blob = self._service.blob(blob_id)
        if blob is None:  # pragma: no cover - ingest guarantees the row
            raise AppError(
                code="MEDIA_BLOB_MISSING", message="媒体文件不存在", status_code=503
            )
        return blob

    def _capability_url(self, *, key: str, upload_id: str, viewer: str) -> str:
        payload = json.dumps(
            {
                "domain": "moment-upload-v1",
                "key": key,
                "upload": upload_id,
                "viewer": viewer,
            },
            separators=(",", ":"),
        )
        if hasattr(self._storage, "moment_read_url"):
            return self._storage.moment_read_url(payload)
        return "media://" + key


def _new_upload_id() -> str:
    from uuid import uuid4

    return str(uuid4())
