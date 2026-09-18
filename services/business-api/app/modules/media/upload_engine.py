"""Upload Engine boundary (ADR-005, requirement §10).

The engine is a **separate subsystem**: it owns the transfer problem (session, chunk,
resume, checksum) and hands a finished byte stream to the platform. The platform never
learns about chunks, and message sending never learns about either.

Phase 4 implements the **interface**: session bookkeeping, resume state and abort work;
chunk upload and commit are deliberately reserved and answer ``501`` with a stable code so
a client can feature-detect instead of guessing. Nothing here encrypts, transcodes or
inspects content, and the E2EE constraint is recorded where it will be needed: a client
must encrypt before chunking and keep the CTR counter continuous across parts (ADR-005).
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import timedelta
from typing import Any

from sqlalchemy import select

from app.core.errors import AppError
from app.modules.media.domain import (
    MEDIA_KIND_MAX_BYTES,
    Digest,
    DigestKind,
    EnvelopeMode,
    MediaKind,
    UploadSessionStatus,
    new_upload_id,
)
from app.modules.media.metrics import media_platform_metrics
from app.modules.media.models import MediaUploadSession
from app.modules.media.policy import MediaPlatformPolicy
from app.modules.media.repository import utcnow


@dataclass(frozen=True, slots=True)
class UploadSessionView:
    upload_id: str
    status: str
    part_size: int
    uploaded_bytes: int
    uploaded_parts: tuple[int, ...]
    expires_at: str
    media_id: str | None
    origin_domain: str
    kind: str
    declared_size: int
    declared_mime: str
    #: Capability advertisement: what a Phase 4 client may rely on today.
    resume_supported: bool = True
    chunk_upload_supported: bool = False
    commit_supported: bool = False
    max_parts: int = 0


class MediaUploadEngine:
    """Session lifecycle today, chunked transfer in the phase that implements it."""

    def __init__(
        self,
        session_factory,
        *,
        policy: MediaPlatformPolicy | None = None,
        now_factory=utcnow,
    ) -> None:
        self._session_factory = session_factory
        self._policy = policy or MediaPlatformPolicy()
        self._now = now_factory

    # ------------------------------------------------------------------ #
    # Working surface
    # ------------------------------------------------------------------ #
    def begin(
        self,
        *,
        owner_id: str,
        origin_domain: str,
        kind: MediaKind,
        declared_size: int,
        declared_mime: str,
        idempotency_key: str,
        envelope_mode: EnvelopeMode = EnvelopeMode.NONE,
        envelope_version: int = 1,
        digest_claim: Digest | None = None,
    ) -> UploadSessionView:
        if declared_size <= 0:
            raise AppError(
                code="MEDIA_UPLOAD_SIZE_INVALID",
                message="上传大小不合法",
                status_code=422,
            )
        limit = MEDIA_KIND_MAX_BYTES[kind]
        if declared_size > limit:
            raise AppError(
                code="MEDIA_TOO_LARGE",
                message="媒体超过大小限制",
                status_code=413,
            )
        if digest_claim is not None and digest_claim.kind is not DigestKind.TRANSPORT:
            # Only transport-level claims are acceptable from a client (ADR-002 rule 3).
            raise AppError(
                code="MEDIA_DIGEST_KIND_INVALID",
                message="只有传输摘要可以由客户端声明",
                status_code=422,
            )

        now = self._now()
        with self._session_factory.begin() as session:
            existing = session.scalars(
                select(MediaUploadSession).where(
                    MediaUploadSession.owner_id == owner_id,
                    MediaUploadSession.idempotency_key == idempotency_key,
                )
            ).first()
            if existing is not None:
                if (
                    existing.declared_size != declared_size
                    or existing.declared_mime != declared_mime
                    or existing.kind != kind.value
                ):
                    raise AppError(
                        code="MEDIA_UPLOAD_IDEMPOTENCY_CONFLICT",
                        message="同一幂等键对应不同的上传参数",
                        status_code=409,
                    )
                return self._view(existing)

            row = MediaUploadSession(
                upload_id=new_upload_id(),
                owner_id=owner_id,
                origin_domain=origin_domain,
                kind=kind.value,
                declared_size=declared_size,
                declared_mime=declared_mime,
                digest_claim=digest_claim.value if digest_claim else None,
                digest_claim_kind=str(digest_claim.kind) if digest_claim else None,
                envelope_mode=envelope_mode.value,
                envelope_version=envelope_version,
                part_size=self._policy.upload_part_size_bytes,
                chunks=[],
                uploaded_bytes=0,
                status=UploadSessionStatus.CREATED.value,
                idempotency_key=idempotency_key,
                created_at=now,
                updated_at=now,
                expires_at=now + timedelta(seconds=self._policy.upload_session_ttl_seconds),
            )
            session.add(row)
            media_platform_metrics.increment("upload_session_created")
            return self._view(row)

    def get(self, *, owner_id: str, upload_id: str) -> UploadSessionView:
        row = self._require(owner_id=owner_id, upload_id=upload_id)
        self._expire_if_needed(row)
        return self._view(row)

    def abort(self, *, owner_id: str, upload_id: str) -> UploadSessionView:
        now = self._now()
        with self._session_factory.begin() as session:
            row = self._require(owner_id=owner_id, upload_id=upload_id, session=session)
            if row.status == UploadSessionStatus.COMMITTED.value:
                raise AppError(
                    code="MEDIA_UPLOAD_COMMITTED",
                    message="已完成的上传不能取消",
                    status_code=409,
                )
            if row.status not in (
                UploadSessionStatus.ABORTED.value,
                UploadSessionStatus.EXPIRED.value,
            ):
                row.status = UploadSessionStatus.ABORTED.value
                row.updated_at = now
                row.chunks = []
                row.uploaded_bytes = 0
            media_platform_metrics.increment("upload_session_aborted")
            return self._view(row)

    # ------------------------------------------------------------------ #
    # Reserved surface (ADR-005): interface now, transfer later
    # ------------------------------------------------------------------ #
    def append_chunk(self, *, owner_id: str, upload_id: str, index: int, content: bytes) -> UploadSessionView:
        self._require(owner_id=owner_id, upload_id=upload_id)
        raise AppError(
            code="MEDIA_UPLOAD_NOT_IMPLEMENTED",
            message="分片上传将在后续阶段提供",
            status_code=501,
        )

    def commit(self, *, owner_id: str, upload_id: str) -> UploadSessionView:
        self._require(owner_id=owner_id, upload_id=upload_id)
        raise AppError(
            code="MEDIA_UPLOAD_NOT_IMPLEMENTED",
            message="上传提交将在后续阶段提供",
            status_code=501,
        )

    # ------------------------------------------------------------------ #
    # Internals
    # ------------------------------------------------------------------ #
    def _require(self, *, owner_id: str, upload_id: str, session=None) -> MediaUploadSession:
        if session is not None:
            row = session.get(MediaUploadSession, upload_id)
            if row is None or row.owner_id != owner_id:
                raise AppError(
                    code="MEDIA_UPLOAD_NOT_FOUND",
                    message="上传会话不存在",
                    status_code=404,
                )
            return row
        with self._session_factory() as own_session:
            row = own_session.get(MediaUploadSession, upload_id)
            if row is None or row.owner_id != owner_id:
                raise AppError(
                    code="MEDIA_UPLOAD_NOT_FOUND",
                    message="上传会话不存在",
                    status_code=404,
                )
            return row

    def _expire_if_needed(self, row: MediaUploadSession) -> None:
        expires_at = row.expires_at
        if expires_at.tzinfo is None:
            expires_at = expires_at.replace(tzinfo=utcnow().tzinfo)
        if (
            expires_at <= self._now()
            and row.status
            not in (UploadSessionStatus.COMMITTED.value, UploadSessionStatus.EXPIRED.value)
        ):
            with self._session_factory.begin() as session:
                stored = session.get(MediaUploadSession, row.upload_id)
                if stored is not None and stored.status != UploadSessionStatus.COMMITTED.value:
                    stored.status = UploadSessionStatus.EXPIRED.value
                    stored.chunks = []
                    stored.uploaded_bytes = 0
                    row.status = stored.status

    def _view(self, row: MediaUploadSession) -> UploadSessionView:
        chunks: list[dict[str, Any]] = list(row.chunks or [])
        return UploadSessionView(
            upload_id=row.upload_id,
            status=row.status,
            part_size=row.part_size,
            uploaded_bytes=row.uploaded_bytes,
            uploaded_parts=tuple(int(chunk.get("n", 0)) for chunk in chunks),
            expires_at=row.expires_at.isoformat(),
            media_id=row.media_id,
            origin_domain=row.origin_domain,
            kind=row.kind,
            declared_size=row.declared_size,
            declared_mime=row.declared_mime,
            max_parts=self._policy.upload_max_parts,
        )
