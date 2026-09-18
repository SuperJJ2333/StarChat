"""Media Platform service facade (Phase 4.2).

The facade is the only thing the HTTP layer talks to. It wires the policy bundle, the
repository, the gateway registry, the variant resolver and the upload engine together and
keeps the request path in the frozen order:

``Client → Authorization → Media Resolver → Variant Resolver → delivery → Download``
"""

from __future__ import annotations

from dataclasses import dataclass

from app.core.errors import AppError
from app.modules.media.authorization import Authorizer, OwnerOnlyAuthorizer
from app.modules.media.domain import (
    DigestKind,
    EnvelopeMode,
    MediaKind,
    Permission,
    VariantKind,
    VisibilityTier,
)
from app.modules.media.gateway import (
    BusinessMediaGateway,
    Delivery,
    MatrixMediaGateway,
    MediaGatewayRegistry,
    MediaOrigin,
    MediaResolution,
)
from app.modules.media.metrics import media_platform_metrics
from app.modules.media.policy import (
    MediaPlatformPolicy,
    NetworkHint,
    VariantPreference,
)
from app.modules.media.repository import (
    IngestRequest,
    IngestResult,
    MediaRepository,
)
from app.modules.media.upload_engine import MediaUploadEngine, UploadSessionView
from app.modules.media.variants import VariantCandidate, VariantResolver


@dataclass(frozen=True, slots=True)
class VariantContent:
    media_id: str
    variant_kind: VariantKind
    mime: str
    content: bytes
    size: int
    delivery: Delivery


class MediaPlatformService:
    def __init__(
        self,
        *,
        repository: MediaRepository,
        resolver: VariantResolver,
        registry: MediaGatewayRegistry,
        upload_engine: MediaUploadEngine,
        policy: MediaPlatformPolicy | None = None,
        authorizer: Authorizer | None = None,
    ) -> None:
        self._repository = repository
        self._resolver = resolver
        self._registry = registry
        self._uploads = upload_engine
        self._policy = policy or MediaPlatformPolicy()
        self._authorizer = authorizer or OwnerOnlyAuthorizer(ttl_policy=self._policy.ttl)

    # ------------------------------------------------------------------ #
    # Ingest (Write New)
    # ------------------------------------------------------------------ #
    def ingest(
        self,
        *,
        owner_id: str,
        origin_domain: str,
        kind: MediaKind,
        mime: str,
        content: bytes,
        digest_kind: DigestKind = DigestKind.PLAINTEXT,
        envelope_mode: EnvelopeMode = EnvelopeMode.NONE,
        visibility: VisibilityTier = VisibilityTier.PRIVATE,
        metadata: dict | None = None,
        width: int | None = None,
        height: int | None = None,
        duration_ms: int | None = None,
        max_bytes: int | None = None,
    ) -> IngestResult:
        return self._registry.business.ingest(
            IngestRequest(
                owner_id=owner_id,
                origin_domain=origin_domain,
                kind=kind,
                mime=mime,
                content=content,
                digest_kind=digest_kind,
                envelope_mode=envelope_mode,
                visibility=visibility,
                metadata=metadata,
                width=width,
                height=height,
                duration_ms=duration_ms,
                max_bytes=max_bytes,
            )
        )

    # ------------------------------------------------------------------ #
    # Resolve (dual read: platform first, legacy locators delegated)
    # ------------------------------------------------------------------ #
    def resolve(self, reference: str, *, subject_id: str) -> MediaResolution:
        return self._registry.resolve(reference, subject_id=subject_id)

    def object_metadata(self, media_id: str, *, subject_id: str) -> MediaResolution:
        media = self._repository.get_object(media_id)
        if media is None:
            raise AppError(
                code="MEDIA_OBJECT_NOT_FOUND",
                message="媒体不存在",
                status_code=404,
            )
        decision = self._registry.business.authorize(
            media=media,
            subject_id=subject_id,
            permission=Permission.READ,
            variant_kind=VariantKind.ORIGINAL,
            visibility=VisibilityTier(media.visibility_hint),
        )
        if not decision.allowed:
            raise AppError(
                code="MEDIA_ACCESS_DENIED",
                message="无权访问该媒体",
                status_code=403,
            )
        return self._registry.business.resolve(media_id, subject_id=subject_id)

    # ------------------------------------------------------------------ #
    # Read
    # ------------------------------------------------------------------ #
    def read_variant(
        self,
        *,
        media_id: str,
        subject_id: str,
        variant_kind: VariantKind | None = None,
        prefer: VariantPreference = VariantPreference.AUTO,
        network: NetworkHint = NetworkHint.UNKNOWN,
    ) -> VariantContent:
        media = self._repository.get_object(media_id)
        if media is None:
            raise AppError(
                code="MEDIA_OBJECT_NOT_FOUND",
                message="媒体不存在",
                status_code=404,
            )
        requested = variant_kind or VariantKind.ORIGINAL
        candidate, _decision = self._registry.business.load_authorized_variant(
            media=media,
            subject_id=subject_id,
            variant_kind=requested,
            prefer=prefer,
            network=network,
        )
        self._repository.touch(media.media_id)
        return self._load(candidate)

    def _load(self, candidate: VariantCandidate) -> VariantContent:
        blob = self._repository.get_blob(candidate.blob_id)
        if blob is None:
            raise AppError(
                code="MEDIA_BLOB_MISSING",
                message="媒体文件不存在",
                status_code=503,
            )
        content = self._repository.read_bytes(blob)
        return VariantContent(
            media_id=candidate.media_id,
            variant_kind=candidate.kind,
            mime=candidate.mime or blob.mime,
            content=content,
            size=len(content),
            delivery=Delivery.PLATFORM,
        )

    # ------------------------------------------------------------------ #
    # Upload engine (interface only in Phase 4)
    # ------------------------------------------------------------------ #
    def begin_upload(self, **kwargs) -> UploadSessionView:
        return self._uploads.begin(**kwargs)

    def upload_session(self, *, owner_id: str, upload_id: str) -> UploadSessionView:
        return self._uploads.get(owner_id=owner_id, upload_id=upload_id)

    def abort_upload(self, *, owner_id: str, upload_id: str) -> UploadSessionView:
        return self._uploads.abort(owner_id=owner_id, upload_id=upload_id)

    def append_chunk(self, **kwargs) -> UploadSessionView:
        return self._uploads.append_chunk(**kwargs)

    def commit_upload(self, **kwargs) -> UploadSessionView:
        return self._uploads.commit(**kwargs)

    # ------------------------------------------------------------------ #
    # Diagnostics
    # ------------------------------------------------------------------ #
    @property
    def policy(self) -> MediaPlatformPolicy:
        return self._policy

    @property
    def origin_for_reference(self, reference: str) -> MediaOrigin:  # pragma: no cover
        return self._registry.resolve(reference, subject_id="").origin

    def metrics_snapshot(self) -> dict:
        return media_platform_metrics.snapshot()
