"""Gateway abstraction (Phase 4.2) and the Matrix compatibility adapter (ADR-004).

One gateway, three questions: *resolve* (what is this reference?), *authorize* (may this
subject read it?) and *resolve_variant* (which rendition should be delivered?). Adapters
own the per-domain knowledge; the gateway never lets a domain's rule leak into another's.

**Matrix compatibility (frozen).** The Matrix adapter does not move, copy, re-encrypt or
re-index bytes. It resolves an ``mxc://`` locator and *delegates authorization to Matrix*,
because:

* the platform cannot compute an authoritative digest for an E2EE attachment (it never
  sees the plaintext, and a client-declared digest is not authoritative — ADR-002), so it
  must not invent a platform identity for those bytes;
* Matrix already enforces room membership for the authenticated media endpoints, so
  re-signing the bytes would create a second, weaker authorization path;
* keeping ``mxc://`` as the only locator is what makes "old data always readable" true by
  construction rather than by migration.

Legacy *business* media (``media://…`` and the signed ``/api/v1/moments/media/content/``
capability URLs) is handled the same way: resolve, then delegate to the existing reader.
That is the "Read Old" arm of the strangler adapter; "Write New" goes through ingest.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
from typing import Protocol
from urllib.parse import urlparse

from app.core.errors import AppError
from app.modules.media.authorization import AccessDecision, Authorizer
from app.modules.media.domain import (
    AuthorizationOutcome,
    DerivedRule,
    MediaKind,
    Permission,
    VariantKind,
    VisibilityTier,
)
from app.modules.media.metrics import media_platform_metrics
from app.modules.media.models import MediaObject
from app.modules.media.policy import (
    MediaPlatformPolicy,
    NetworkHint,
    VariantPreference,
)
from app.modules.media.repository import IngestRequest, IngestResult, MediaRepository
from app.modules.media.variants import VariantCandidate, VariantResolver


class MediaOrigin(StrEnum):
    PLATFORM = "platform"
    MATRIX = "matrix"
    LEGACY_BUSINESS = "legacy_business"


class Delivery(StrEnum):
    """How the bytes reach the client."""

    PLATFORM = "platform"  # platform-signed URL or authorized platform read
    MATRIX_TOKEN = "matrix_token"  # the client uses its own Matrix token
    LEGACY_CAPABILITY = "legacy_capability"  # the existing business signed URL keeps working


@dataclass(frozen=True, slots=True)
class ResolvedVariantView:
    kind: str
    size: int | None
    mime: str | None
    width: int | None
    height: int | None
    duration_ms: int | None


@dataclass(frozen=True, slots=True)
class MediaResolution:
    origin: MediaOrigin
    media_id: str
    kind: str
    status: str
    visibility: str
    delivery: Delivery
    variants: tuple[ResolvedVariantView, ...]
    delegated_to: str | None = None
    requires_matrix_token: bool = False
    read_old_only: bool = False


class MediaGateway(Protocol):
    """Uniform gateway surface: resolve / authorize / resolveVariant."""

    origin: MediaOrigin

    def can_resolve(self, reference: str) -> bool: ...

    def resolve(self, reference: str, *, subject_id: str) -> MediaResolution: ...

    def authorize(
        self,
        *,
        media,
        subject_id: str,
        permission: Permission,
        variant_kind: VariantKind,
        visibility: VisibilityTier,
    ) -> AccessDecision: ...

    def resolve_variant(
        self,
        media_id: str,
        *,
        media_kind: MediaKind,
        prefer: VariantPreference,
        network: NetworkHint,
        allowed_kinds: frozenset[VariantKind] | None = None,
    ) -> VariantCandidate | None: ...


class MatrixMediaGateway:
    """Read-only adapter over existing Matrix media. Never migrates data."""

    origin = MediaOrigin.MATRIX

    def can_resolve(self, reference: str) -> bool:
        return reference.startswith("mxc://")

    def resolve(self, reference: str, *, subject_id: str) -> MediaResolution:
        parsed = urlparse(reference)
        if parsed.scheme != "mxc" or not parsed.netloc or not parsed.path.strip("/"):
            raise AppError(
                code="MEDIA_REFERENCE_INVALID",
                message="媒体引用无效",
                status_code=422,
            )
        media_platform_metrics.increment("legacy_read_delegated")
        media_platform_metrics.increment("media_resolve")
        # No bytes, no digest, no platform identity: the locator stays authoritative and
        # the client keeps using its Matrix token. Old messages therefore never need a
        # migration and E2EE is untouched.
        return MediaResolution(
            origin=MediaOrigin.MATRIX,
            media_id=reference,
            kind=MediaKind.FILE.value,
            status="LEGACY",
            visibility=VisibilityTier.PRIVATE.value,
            delivery=Delivery.MATRIX_TOKEN,
            variants=(),
            delegated_to="matrix",
            requires_matrix_token=True,
            read_old_only=True,
        )

    def authorize(
        self,
        *,
        media,
        subject_id: str,
        permission: Permission,
        variant_kind: VariantKind,
        visibility: VisibilityTier,
    ) -> AccessDecision:
        media_platform_metrics.increment("authorization")
        return AccessDecision(
            outcome=AuthorizationOutcome.DELEGATED,
            rule=DerivedRule.ROOM_MEMBERSHIP,
            ttl_seconds=0,
            reason="matrix_is_the_authority",
            delegate_to="matrix",
        )

    def resolve_variant(self, media_id: str, **_: object) -> None:
        # Matrix media has no platform variants; the Matrix thumbnail/body locators in the
        # encrypted event remain the source of truth.
        return None


class BusinessMediaGateway:
    """Adapter for platform-owned (plaintext) media: Moments, files, future domains."""

    origin = MediaOrigin.PLATFORM

    def __init__(
        self,
        *,
        repository: MediaRepository,
        resolver: VariantResolver,
        authorizer: Authorizer,
        policy: MediaPlatformPolicy,
    ) -> None:
        self._repository = repository
        self._resolver = resolver
        self._authorizer = authorizer
        self._policy = policy

    # -- ingest (Write New) ------------------------------------------------
    def ingest(self, request: IngestRequest) -> IngestResult:
        return self._repository.ingest(request)

    # -- resolve -----------------------------------------------------------
    def can_resolve(self, reference: str) -> bool:
        if self._is_legacy_business_reference(reference):
            return True
        return self._repository.get_object(reference) is not None

    @staticmethod
    def _is_legacy_business_reference(reference: str) -> bool:
        return reference.startswith("media://") or "/api/v1/moments/media/content/" in reference

    def resolve(self, reference: str, *, subject_id: str) -> MediaResolution:
        with media_platform_metrics.timed("media_resolve_ms"):
            if self._is_legacy_business_reference(reference):
                # Read Old: the existing capability token stays valid; the platform does
                # not copy the bytes and does not need a platform object to serve them.
                media_platform_metrics.increment("media_resolve")
                return MediaResolution(
                    origin=MediaOrigin.LEGACY_BUSINESS,
                    media_id=reference,
                    kind=MediaKind.IMAGE.value,
                    status="LEGACY",
                    visibility=VisibilityTier.AUDIENCE.value,
                    delivery=Delivery.LEGACY_CAPABILITY,
                    variants=(),
                    delegated_to="business_legacy_reader",
                    read_old_only=True,
                )
            media = self._repository.get_object(reference)
            if media is None:
                raise AppError(
                    code="MEDIA_OBJECT_NOT_FOUND",
                    message="媒体不存在",
                    status_code=404,
                )
            variants = self._resolver.ready_variants(media.media_id)
            media_platform_metrics.increment("media_resolve")
            return MediaResolution(
                origin=MediaOrigin.PLATFORM,
                media_id=media.media_id,
                kind=media.kind,
                status=media.status,
                visibility=media.visibility_hint,
                delivery=Delivery.PLATFORM,
                variants=tuple(
                    ResolvedVariantView(
                        kind=candidate.kind.value,
                        size=candidate.size,
                        mime=candidate.mime,
                        width=candidate.width,
                        height=candidate.height,
                        duration_ms=candidate.duration_ms,
                    )
                    for candidate in variants.values()
                ),
            )

    # -- authorize / resolveVariant ---------------------------------------
    def authorize(
        self,
        *,
        media,
        subject_id: str,
        permission: Permission,
        variant_kind: VariantKind,
        visibility: VisibilityTier,
    ) -> AccessDecision:
        return self._authorizer.authorize(
            media=media,
            subject_id=subject_id,
            permission=permission,
            variant_kind=variant_kind,
            visibility=visibility,
        )

    def resolve_variant(
        self,
        media_id: str,
        *,
        media_kind: MediaKind,
        prefer: VariantPreference = VariantPreference.AUTO,
        network: NetworkHint = NetworkHint.UNKNOWN,
        allowed_kinds: frozenset[VariantKind] | None = None,
    ) -> VariantCandidate | None:
        return self._resolver.best(
            media_id,
            media_kind=media_kind,
            prefer=prefer,
            network=network,
            allowed_kinds=allowed_kinds,
        )

    # -- object helpers ----------------------------------------------------
    def get_object(self, media_id: str) -> MediaObject | None:
        return self._repository.get_object(media_id)

    def load_authorized_variant(
        self,
        *,
        media: MediaObject,
        subject_id: str,
        variant_kind: VariantKind,
        prefer: VariantPreference = VariantPreference.AUTO,
        network: NetworkHint = NetworkHint.UNKNOWN,
    ) -> tuple[VariantCandidate, AccessDecision]:
        """Authorize, then resolve the variant, then return bytes-agnostic candidate."""

        decision = self.authorize(
            media=media,
            subject_id=subject_id,
            permission=Permission.READ,
            variant_kind=variant_kind,
            visibility=VisibilityTier(media.visibility_hint),
        )
        if not decision.allowed:
            raise AppError(
                code="MEDIA_ACCESS_DENIED",
                message="无权访问该媒体",
                status_code=403,
            )
        allowed = None
        if decision.variant_scope is not None:
            allowed = frozenset(decision.variant_scope)
        candidate = self.resolve_variant(
            media.media_id,
            media_kind=MediaKind(media.kind),
            prefer=prefer,
            network=network,
            allowed_kinds=allowed,
        ) or self.resolve_variant(
            media.media_id,
            media_kind=MediaKind(media.kind),
            prefer=prefer,
            network=network,
        )
        if candidate is None:
            raise AppError(
                code="MEDIA_VARIANT_UNAVAILABLE",
                message="媒体暂时不可用，请稍后重试",
                status_code=409,
                retry_after_seconds=2,
            )
        if not decision.allows_variant(candidate.kind):
            raise AppError(
                code="MEDIA_ACCESS_DENIED",
                message="无权访问该清晰度",
                status_code=403,
            )
        return candidate, decision


class MediaGatewayRegistry:
    """Routes a reference to the adapter that owns it.

    Order matters: locators with an explicit scheme are matched first (they are the "Read
    Old" paths), then platform objects. An unknown reference never silently falls through
    to a permissive adapter.
    """

    def __init__(self, *, matrix: MatrixMediaGateway, business: BusinessMediaGateway) -> None:
        self._matrix = matrix
        self._business = business

    @property
    def matrix(self) -> MatrixMediaGateway:
        return self._matrix

    @property
    def business(self) -> BusinessMediaGateway:
        return self._business

    def resolve(self, reference: str, *, subject_id: str) -> MediaResolution:
        if self._matrix.can_resolve(reference):
            return self._matrix.resolve(reference, subject_id=subject_id)
        return self._business.resolve(reference, subject_id=subject_id)
