"""Media Platform service facade (Phase 4.2).

The facade is the only thing the HTTP layer talks to. It wires the policy bundle, the
repository, the gateway registry, the variant resolver and the upload engine together and
keeps the request path in the frozen order:

``Client → Authorization → Media Resolver → Variant Resolver → delivery → Download``
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

from app.core.errors import AppError
from app.modules.media.audience import AudienceRegistry, assert_audience_is_verifiable
from app.modules.media.authorization import Authorizer, OwnerOnlyAuthorizer
from app.modules.media.domain import (
    DigestKind,
    EnvelopeMode,
    GcMode,
    MediaKind,
    Permission,
    SubjectType,
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
from app.modules.media.references import MediaReferenceService, ReferenceView
from app.modules.media.repository import (
    IngestRequest,
    IngestResult,
    MediaRepository,
)
from app.modules.media.upload_engine import MediaUploadEngine, UploadSessionView
from app.modules.media.variants import VariantCandidate, VariantResolver

if TYPE_CHECKING:  # pragma: no cover - typing only
    from app.modules.media.audience import AudienceRegistry
    from app.modules.media.grants import GrantView, MediaGrantService
    from app.modules.media.reconcile import MediaReconciler, ReconcileReport
    from app.modules.media.lifecycle import GcReport, MediaGarbageCollector
    from app.modules.media.signed_urls import MediaSignedUrlCodec, SignedToken


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
        references: "MediaReferenceService | None" = None,
        collector: "MediaGarbageCollector | None" = None,
        grants: "MediaGrantService | None" = None,
        codec: "MediaSignedUrlCodec | None" = None,
        audience: "AudienceRegistry | None" = None,
        reconciler: "MediaReconciler | None" = None,
    ) -> None:
        self._repository = repository
        self._resolver = resolver
        self._registry = registry
        self._uploads = upload_engine
        self._policy = policy or MediaPlatformPolicy()
        self._authorizer = authorizer or OwnerOnlyAuthorizer(ttl_policy=self._policy.ttl)
        self._references = references
        self._collector = collector
        self._grants = grants
        self._codec = codec or MediaSignedUrlCodec(secret=None)
        self._audience = audience
        self._reconciler = reconciler

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
        key_namespace: str | None = None,
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
                key_namespace=key_namespace,
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
    # References (Phase 4.3) and lifecycle (Phase 4.6)
    # ------------------------------------------------------------------ #
    @property
    def references(self) -> "MediaReferenceService":
        if self._references is None:  # pragma: no cover - wiring guard
            raise AppError(
                code="MEDIA_REFERENCES_UNAVAILABLE",
                message="媒体引用服务不可用",
                status_code=503,
            )
        return self._references

    def attach_reference(self, **kwargs) -> "ReferenceView":
        return self.references.attach(**kwargs)

    def release_reference(self, **kwargs) -> "ReferenceView":
        return self.references.release(**kwargs)

    def references_for(self, media_id: str, *, include_released: bool = False):
        return self.references.list_for_media(media_id, include_released=include_released)

    def run_garbage_collection(self, *, mode: GcMode = GcMode.DRY_RUN, owner_id: str | None = None, limit: int = 200) -> "GcReport":
        if self._collector is None:  # pragma: no cover - wiring guard
            raise AppError(
                code="MEDIA_GC_UNAVAILABLE",
                message="媒体回收服务不可用",
                status_code=503,
            )
        return self._collector.run(mode=mode, owner_id=owner_id, limit=limit)

    def reconcile_storage(self, *, dry_run: bool = True) -> "ReconcileReport":
        if self._reconciler is None:  # pragma: no cover - wiring guard
            raise AppError(
                code="MEDIA_RECONCILE_UNAVAILABLE",
                message="媒体对账服务不可用",
                status_code=503,
            )
        return self._reconciler.run(dry_run=dry_run)

    def pin(self, media_id: str, *, seconds: int) -> None:
        from app.modules.media.lifecycle import pin_object

        pin_object(self._repository.session_factory, media_id=media_id, seconds=seconds)

    def unpin(self, media_id: str) -> None:
        from app.modules.media.lifecycle import unpin_object

        unpin_object(self._repository.session_factory, media_id=media_id)

    # ------------------------------------------------------------------ #
    # Grants and signed URLs (Phase 4.4)
    # ------------------------------------------------------------------ #
    @property
    def grants(self) -> "MediaGrantService":
        if self._grants is None:  # pragma: no cover - wiring guard
            raise AppError(
                code="MEDIA_GRANTS_UNAVAILABLE",
                message="媒体授权服务不可用",
                status_code=503,
            )
        return self._grants

    def issue_grant(self, **kwargs) -> "GrantView":
        return self.grants.issue(**kwargs)

    def revoke_grant(self, *, grant_id: str, actor_id: str, reason: str = "owner_revoked"):
        return self.grants.revoke(grant_id=grant_id, actor_id=actor_id, reason=reason)

    def grants_for(self, media_id: str, *, include_revoked: bool = False):
        return self.grants.list_for_media(media_id, include_revoked=include_revoked)

    def mint_signed_url(
        self,
        *,
        media_id: str,
        variant_kind: VariantKind,
        actor_id: str,
        tier: VisibilityTier | None = None,
        aud_scope: str | None = None,
    ) -> tuple[str, "SignedToken"]:
        """Mint a URL whose lifetime the *server* decides from the object's tier.

        The caller cannot pass a TTL: there is no such parameter on the API surface, which
        is what makes the frozen "server decides TTL" rule hold by construction.
        """

        media = self._repository.get_object(media_id)
        if media is None:
            raise AppError(
                code="MEDIA_OBJECT_NOT_FOUND", message="媒体不存在", status_code=404
            )
        effective_tier = tier or VisibilityTier(media.visibility_hint)
        decision = self._registry.business.authorize(
            media=media,
            subject_id=actor_id,
            permission=Permission.READ,
            variant_kind=variant_kind,
            visibility=effective_tier,
        )
        if not decision.allowed and not self._is_service_grant(media_id=media_id, actor_id=actor_id):
            raise AppError(
                code="MEDIA_ACCESS_DENIED", message="无权访问该媒体", status_code=403
            )
        if decision.variant_scope is not None and variant_kind not in decision.variant_scope:
            raise AppError(
                code="MEDIA_ACCESS_DENIED", message="无权访问该清晰度", status_code=403
            )
        ttl = decision.ttl_seconds or self._policy.ttl.ttl_seconds(
            visibility=effective_tier, variant_kind=variant_kind
        )
        if effective_tier is VisibilityTier.AUDIENCE:
            # Fail closed at mint time: no token for an audience the platform cannot re-check.
            if self._audience is None:
                raise AppError(
                    code="MEDIA_AUDIENCE_UNVERIFIABLE",
                    message="该受众无法校验，已拒绝签发链接",
                    status_code=422,
                )
            assert_audience_is_verifiable(self._audience, aud_scope)
        token, parsed = self._codec.mint(
            media_id=media_id,
            variant_kind=variant_kind,
            subject=actor_id if effective_tier is VisibilityTier.PRIVATE else (aud_scope or actor_id),
            tier=effective_tier,
            ttl_seconds=ttl,
            aud_scope=aud_scope,
            grant_id=decision.grant_id,
            grant_version=decision.grant_version,
            single_use=decision.single_use,
        )
        return token, parsed

    def read_via_signed_token(self, token: str, *, caller_id: str | None) -> VariantContent:
        parsed = self._codec.verify(token, caller_id=caller_id)
        if parsed.tier is VisibilityTier.AUDIENCE:
            # Membership is re-checked live on every delivery, so a forwarded audience URL
            # only works for someone who is still in the audience (ADR-003 §4.3.3).
            if self._audience is None or not self._audience.verify(
                parsed.aud_scope, caller_id=caller_id
            ):
                raise AppError(
                    code="MEDIA_SIGNED_URL_INVALID",
                    message="媒体链接无效或已过期",
                    status_code=404,
                )
        media = self._repository.get_object(parsed.media_id)
        if media is None:
            raise AppError(
                code="MEDIA_SIGNED_URL_INVALID",
                message="媒体链接无效或已过期",
                status_code=404,
            )
        # Revocation beats the TTL: a forwarded audience URL dies with its grant.
        if parsed.grant_id is not None:
            grant = self.grants.get(parsed.grant_id)
            if grant is None or grant.revoked_at is not None:
                raise AppError(
                    code="MEDIA_SIGNED_URL_INVALID",
                    message="媒体链接无效或已过期",
                    status_code=404,
                )
            if parsed.grant_version is not None and grant.grant_version != parsed.grant_version:
                raise AppError(
                    code="MEDIA_SIGNED_URL_INVALID",
                    message="媒体链接无效或已过期",
                    status_code=404,
                )
        candidate = self._resolver.best(
            parsed.media_id,
            media_kind=MediaKind(media.kind),
            prefer=VariantPreference.AUTO,
            network=NetworkHint.UNKNOWN,
            allowed_kinds=frozenset({parsed.variant_kind}),
        )
        if candidate is None:
            raise AppError(
                code="MEDIA_VARIANT_UNAVAILABLE",
                message="媒体暂时不可用，请稍后重试",
                status_code=409,
                retry_after_seconds=2,
            )
        if parsed.grant_id is not None:
            self.grants.consume(parsed.grant_id)
        return self._load(candidate)

    def _is_service_grant(self, *, media_id: str, actor_id: str) -> bool:
        grant = self.grants.active_for_subject(
            media_id=media_id,
            subject_type=SubjectType.SERVICE,
            subject_id=actor_id,
            permission=Permission.READ,
        )
        return grant is not None

    # ------------------------------------------------------------------ #
    # Diagnostics
    # ------------------------------------------------------------------ #
    @property
    def policy(self) -> MediaPlatformPolicy:
        return self._policy

    def blob(self, blob_id: str):
        """Blob accessor used by the Moments bridge to learn a blob's storage key."""

        return self._repository.get_blob(blob_id)

    @property
    def origin_for_reference(self, reference: str) -> MediaOrigin:  # pragma: no cover
        return self._registry.resolve(reference, subject_id="").origin

    def metrics_snapshot(self) -> dict:
        return media_platform_metrics.snapshot()
