"""Media Platform HTTP surface (Phase 4.2).

New endpoints only: nothing here changes the existing Matrix, Moments, Avatar or media
compress contracts, and no old endpoint is removed or re-pointed (strangler pattern).

Reads always flow through the frozen order — the handler never touches the storage layer
directly::

    Client → Authorization → Media Resolver → Variant Resolver → delivery → bytes

Maintenance endpoints (GC, metrics) are gated by a shared token. When no token is
configured they are available in non-production environments only, and answer 503 in
production — fail closed rather than expose an unauthenticated collector.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Header, Query, Request, Response

from app.core.config import Settings
from app.core.errors import AppError
from app.modules.media.domain import (
    DigestKind,
    EnvelopeMode,
    MediaKind,
    VariantKind,
    VisibilityTier,
)
from app.modules.media.metrics import media_platform_metrics
from app.modules.media.policy import NetworkHint, VariantPreference
from app.modules.media.service import MediaPlatformService
from app.modules.identity.tokens import TokenService


def _media_kind(value: str) -> MediaKind:
    try:
        return MediaKind(value)
    except ValueError:
        raise AppError(
            code="MEDIA_KIND_INVALID",
            message="媒体类型不合法",
            status_code=422,
        ) from None


def create_media_platform_router(
    settings: Settings,
    session_factory,
    *,
    service: MediaPlatformService,
) -> APIRouter:
    router = APIRouter(tags=["media-platform"])
    tokens = TokenService(
        session_factory,
        jwt_secret=settings.jwt_secret
        or "development-jwt-secret-at-least-thirty-two-bytes",
        jwt_issuer=settings.jwt_issuer,
        require_session_claims=settings.environment != "test",
    )

    def current_claims(
        authorization: Annotated[str | None, Header()] = None,
    ) -> dict:
        if not authorization or not authorization.startswith("Bearer "):
            raise AppError(code="AUTH_REQUIRED", message="需要登录", status_code=401)
        return tokens.decode_access_token(authorization[7:])

    def require_maintenance(
        token: Annotated[str | None, Header(alias="X-Media-Maintenance-Token")] = None,
    ) -> None:
        expected = settings.media_maintenance_token
        if expected:
            if token != expected:
                raise AppError(
                    code="MEDIA_MAINTENANCE_FORBIDDEN",
                    message="维护接口不可用",
                    status_code=403,
                )
            return
        if settings.environment == "production":
            raise AppError(
                code="MEDIA_MAINTENANCE_UNAVAILABLE",
                message="维护接口未配置",
                status_code=503,
            )

    # ------------------------------------------------------------------ #
    # Upload engine (interface: session lifecycle works, transfer is reserved)
    # ------------------------------------------------------------------ #
    @router.post("/media/platform/uploads", status_code=201)
    async def begin_upload(
        request: Request,
        kind: Annotated[str, Query()],
        declared_size: Annotated[int, Query(gt=0)],
        declared_mime: Annotated[str, Query(min_length=3, max_length=120)],
        idempotency_key: Annotated[
            str, Header(alias="Idempotency-Key", min_length=1, max_length=128)
        ],
        origin_domain: Annotated[str, Query(max_length=20)] = "moments",
        envelope: Annotated[str, Query(max_length=24)] = EnvelopeMode.NONE.value,
        claims: dict = Depends(current_claims),
    ) -> dict:
        try:
            envelope_mode = EnvelopeMode(envelope)
        except ValueError:
            raise AppError(
                code="MEDIA_ENVELOPE_INVALID",
                message="加密信封不合法",
                status_code=422,
            ) from None
        view = service.begin_upload(
            owner_id=claims["sub"],
            origin_domain=origin_domain,
            kind=_media_kind(kind),
            declared_size=declared_size,
            declared_mime=declared_mime,
            idempotency_key=idempotency_key,
            envelope_mode=envelope_mode,
        )
        return _upload_payload(view)

    @router.get("/media/platform/uploads/{upload_id}")
    async def read_upload(upload_id: str, claims: dict = Depends(current_claims)) -> dict:
        view = service.upload_session(owner_id=claims["sub"], upload_id=upload_id)
        return _upload_payload(view)

    @router.delete("/media/platform/uploads/{upload_id}")
    async def abort_upload(upload_id: str, claims: dict = Depends(current_claims)) -> dict:
        view = service.abort_upload(owner_id=claims["sub"], upload_id=upload_id)
        return _upload_payload(view)

    @router.put("/media/platform/uploads/{upload_id}/parts/{index}")
    async def append_part(
        upload_id: str,
        index: int,
        request: Request,
        claims: dict = Depends(current_claims),
    ) -> Response:
        content = await request.body()
        service.append_chunk(
            owner_id=claims["sub"], upload_id=upload_id, index=index, content=content
        )
        return Response(status_code=501)

    @router.post("/media/platform/uploads/{upload_id}/complete")
    async def commit_upload(upload_id: str, claims: dict = Depends(current_claims)) -> Response:
        service.commit_upload(owner_id=claims["sub"], upload_id=upload_id)
        return Response(status_code=501)

    # ------------------------------------------------------------------ #
    # Direct ingest (small media; the chunked path is the reserved engine)
    # ------------------------------------------------------------------ #
    @router.post("/media/platform/objects", status_code=201)
    async def ingest_object(
        request: Request,
        kind: Annotated[str, Query()],
        mime: Annotated[str, Query(min_length=3, max_length=120)],
        origin_domain: Annotated[str, Query(max_length=20)] = "moments",
        visibility: Annotated[str, Query(max_length=16)] = VisibilityTier.PRIVATE.value,
        digest_kind: Annotated[str, Query(max_length=32)] = DigestKind.PLAINTEXT.value,
        envelope: Annotated[str, Query(max_length=24)] = EnvelopeMode.NONE.value,
        claims: dict = Depends(current_claims),
    ) -> dict:
        # No ``Idempotency-Key`` here on purpose: direct ingest is *content addressed*, so
        # a retry of the same bytes converges on the same blob instead of needing a key.
        # Session creation does require one, because sessions are not content addressed.
        content = await request.body()
        if not content:
            raise AppError(
                code="MEDIA_CONTENT_REQUIRED", message="媒体内容为空", status_code=422
            )
        if len(content) > settings.media_max_upload_bytes:
            raise AppError(
                code="MEDIA_TOO_LARGE", message="媒体超过大小限制", status_code=413
            )
        parsed_kind = _media_kind(kind)
        try:
            parsed_digest_kind = DigestKind(digest_kind)
            parsed_envelope = EnvelopeMode(envelope)
            parsed_visibility = VisibilityTier(visibility)
        except ValueError:
            raise AppError(
                code="MEDIA_INGEST_PARAMETERS_INVALID",
                message="媒体参数不合法",
                status_code=422,
            ) from None
        result = service.ingest(
            owner_id=claims["sub"],
            origin_domain=origin_domain,
            kind=parsed_kind,
            mime=(request.headers.get("content-type") or mime).split(";")[0].strip()
            or mime,
            content=content,
            digest_kind=parsed_digest_kind,
            envelope_mode=parsed_envelope,
            visibility=parsed_visibility,
        )
        return {
            "media_id": result.media_id,
            "blob_id": result.blob_id,
            "variant_id": result.variant_id,
            "size": result.size,
            "digest_kind": str(result.digest_kind),
            "reused_object": result.reused_object,
            "reused_blob": result.reused_blob,
        }

    # ------------------------------------------------------------------ #
    # Resolve (dual read) and read
    # ------------------------------------------------------------------ #
    @router.get("/media/platform/objects/{media_id}")
    async def read_object(media_id: str, claims: dict = Depends(current_claims)) -> dict:
        resolution = service.object_metadata(media_id, subject_id=claims["sub"])
        return {
            "media_id": resolution.media_id,
            "origin": str(resolution.origin),
            "kind": resolution.kind,
            "status": resolution.status,
            "visibility": resolution.visibility,
            "delivery": str(resolution.delivery),
            "read_old_only": resolution.read_old_only,
            "requires_matrix_token": resolution.requires_matrix_token,
            "variants": [
                {
                    "kind": variant.kind,
                    "size": variant.size,
                    "mime": variant.mime,
                    "width": variant.width,
                    "height": variant.height,
                    "duration_ms": variant.duration_ms,
                }
                for variant in resolution.variants
            ],
        }

    @router.get("/media/platform/resolve")
    async def resolve_reference(
        reference: Annotated[str, Query(min_length=1, max_length=1024)],
        claims: dict = Depends(current_claims),
    ) -> dict:
        resolution = service.resolve(reference, subject_id=claims["sub"])
        return {
            "reference": reference,
            "origin": str(resolution.origin),
            "media_id": resolution.media_id,
            "delivery": str(resolution.delivery),
            "delegated_to": resolution.delegated_to,
            "requires_matrix_token": resolution.requires_matrix_token,
            "read_old_only": resolution.read_old_only,
        }

    @router.get("/media/platform/objects/{media_id}/variants/{variant_kind}")
    async def read_variant(
        media_id: str,
        variant_kind: str,
        claims: dict = Depends(current_claims),
        prefer: Annotated[str, Query(max_length=16)] = VariantPreference.AUTO.value,
        network: Annotated[str, Query(max_length=16)] = NetworkHint.UNKNOWN.value,
    ) -> Response:
        try:
            parsed_variant = VariantKind(variant_kind)
            parsed_prefer = VariantPreference(prefer)
            parsed_network = NetworkHint(network)
        except ValueError:
            raise AppError(
                code="MEDIA_VARIANT_KIND_INVALID",
                message="媒体演绎版不合法",
                status_code=422,
            ) from None
        content = service.read_variant(
            media_id=media_id,
            subject_id=claims["sub"],
            variant_kind=parsed_variant,
            prefer=parsed_prefer,
            network=parsed_network,
        )
        return Response(
            content=content.content,
            media_type=content.mime,
            headers={
                "Cache-Control": "private, no-store",
                "Referrer-Policy": "no-referrer",
                "X-Content-Type-Options": "nosniff",
                "Content-Disposition": "inline",
            },
        )

    # ------------------------------------------------------------------ #
    # Diagnostics (maintenance gated)
    # ------------------------------------------------------------------ #
    @router.get("/media/platform/metrics")
    async def read_metrics(_: None = Depends(require_maintenance)) -> dict:
        return media_platform_metrics.snapshot()

    return router


def _upload_payload(view) -> dict:
    return {
        "upload_id": view.upload_id,
        "status": view.status,
        "part_size": view.part_size,
        "uploaded_bytes": view.uploaded_bytes,
        "uploaded_parts": list(view.uploaded_parts),
        "expires_at": view.expires_at,
        "media_id": view.media_id,
        "origin_domain": view.origin_domain,
        "kind": view.kind,
        "declared_size": view.declared_size,
        "declared_mime": view.declared_mime,
        "resume_supported": view.resume_supported,
        "chunk_upload_supported": view.chunk_upload_supported,
        "commit_supported": view.commit_supported,
        "max_parts": view.max_parts,
    }
