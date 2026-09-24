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

from datetime import datetime, timezone
from typing import Annotated

from fastapi import APIRouter, Depends, Header, Query, Request, Response
from pydantic import BaseModel, ConfigDict, Field

from app.core.config import Settings
from app.core.errors import AppError
from app.api.maintenance import media_maintenance_dependency
from app.modules.media.domain import (
    BusinessType,
    DigestKind,
    EnvelopeMode,
    GcMode,
    MediaKind,
    Permission,
    ReferenceKind,
    ReleaseReason,
    SubjectType,
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


class ReferenceAttachRequest(BaseModel):
    """Attach payload. Strict: an unknown field is a client bug, not something to ignore."""

    model_config = ConfigDict(extra="forbid")

    business_type: str = Field(min_length=3, max_length=32)
    business_id: str = Field(min_length=1, max_length=160)
    variant_kind: str | None = Field(default=None, max_length=24)
    room_ref: str | None = Field(default=None, max_length=160)
    permission_scope: str = Field(default=VisibilityTier.PRIVATE.value, max_length=16)
    ref_kind: str = Field(default=ReferenceKind.OBSERVED.value, max_length=16)


class GrantIssueRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    subject_type: str = Field(default=SubjectType.USER.value, max_length=16)
    subject_id: str = Field(min_length=1, max_length=160)
    permission: str = Field(default=Permission.READ.value, max_length=24)
    variant_scope: list[str] | None = Field(default=None, max_length=16)
    ttl_seconds: int = Field(default=600, gt=0, le=86400)
    single_use: bool = False
    max_uses: int | None = Field(default=None, gt=0, le=1000)
    derived_from: dict | None = None


class SignedUrlRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    variant_kind: str = Field(min_length=1, max_length=24)
    tier: str | None = Field(default=None, max_length=16)
    audience: str | None = Field(default=None, max_length=160)


class BusinessReleaseRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    business_type: str = Field(min_length=3, max_length=32)
    business_id: str = Field(min_length=1, max_length=160)


def create_media_platform_router(
    settings: Settings,
    session_factory,
    *,
    service: MediaPlatformService,
    bridge=None,
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

    require_maintenance = media_maintenance_dependency(settings)

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
    # References and lifecycle (Phase 4.3 / 4.6)
    # ------------------------------------------------------------------ #
    @router.post("/media/platform/objects/{media_id}/references", status_code=201)
    async def attach_reference(
        media_id: str,
        body: "ReferenceAttachRequest",
        claims: dict = Depends(current_claims),
    ) -> dict:
        try:
            business_type = BusinessType(body.business_type)
            permission_scope = VisibilityTier(body.permission_scope)
            ref_kind = ReferenceKind(body.ref_kind)
        except ValueError:
            raise AppError(
                code="MEDIA_REFERENCE_INVALID",
                message="业务引用不合法",
                status_code=422,
            ) from None
        view = service.attach_reference(
            media_id=media_id,
            actor_id=claims["sub"],
            business_type=business_type,
            business_id=body.business_id,
            variant_kind=body.variant_kind,
            room_ref=body.room_ref,
            permission_scope=permission_scope,
            ref_kind=ref_kind,
        )
        return _reference_payload(view)

    @router.get("/media/platform/objects/{media_id}/references")
    async def list_references(
        media_id: str,
        claims: dict = Depends(current_claims),
        include_released: Annotated[bool, Query()] = False,
    ) -> dict:
        views = service.references_for(media_id, include_released=include_released)
        return {"items": [_reference_payload(view) for view in views]}

    @router.delete("/media/platform/references/{reference_id}")
    async def release_reference(
        reference_id: str,
        claims: dict = Depends(current_claims),
        reason: Annotated[str, Query(max_length=32)] = ReleaseReason.USER_DELETE.value,
    ) -> dict:
        try:
            parsed_reason = ReleaseReason(reason)
        except ValueError:
            raise AppError(
                code="MEDIA_REFERENCE_INVALID",
                message="释放原因不合法",
                status_code=422,
            ) from None
        view = service.release_reference(
            reference_id=reference_id, actor_id=claims["sub"], reason=parsed_reason
        )
        return _reference_payload(view)

    @router.post("/media/platform/objects/{media_id}/pin")
    async def pin_object(
        media_id: str,
        claims: dict = Depends(current_claims),
        seconds: Annotated[int, Query(gt=0, le=86400)] = 3600,
    ) -> dict:
        # Pinning is an owner action: the metadata read below denies non-owners.
        _may_pin(service, media_id, claims["sub"])
        service.pin(media_id, seconds=seconds)
        return {"media_id": media_id, "pinned_seconds": seconds}

    @router.post("/media/platform/gc")
    async def run_gc(
        mode: Annotated[str, Query(max_length=12)] = GcMode.DRY_RUN.value,
        owner_id: Annotated[str | None, Query(max_length=36)] = None,
        limit: Annotated[int, Query(gt=0, le=1000)] = 200,
        _: None = Depends(require_maintenance),
    ) -> dict:
        try:
            parsed_mode = GcMode(mode)
        except ValueError:
            raise AppError(
                code="MEDIA_GC_MODE_INVALID",
                message="回收模式不合法",
                status_code=422,
            ) from None
        report = service.run_garbage_collection(
            mode=parsed_mode, owner_id=owner_id, limit=limit
        )
        return {
            "run_id": report.run_id,
            "mode": report.mode,
            "dry_run": report.dry_run,
            "scope": report.scope,
            "scanned": report.scanned,
            "candidates": report.candidates,
            "collected": report.collected,
            "bytes_reclaimed": report.bytes_reclaimed,
            "skipped": report.skipped,
            "decisions": [
                {
                    "media_id": decision.media_id,
                    "action": decision.action,
                    "reason": decision.reason,
                }
                for decision in report.decisions
            ],
        }

    # ------------------------------------------------------------------ #
    # Grants and signed URLs (Phase 4.4)
    # ------------------------------------------------------------------ #
    @router.post("/media/platform/objects/{media_id}/grants", status_code=201)
    async def issue_grant(
        media_id: str,
        body: "GrantIssueRequest",
        claims: dict = Depends(current_claims),
    ) -> dict:
        try:
            subject_type = SubjectType(body.subject_type)
            permission = Permission(body.permission)
        except ValueError:
            raise AppError(
                code="MEDIA_GRANT_INVALID", message="授权参数不合法", status_code=422
            ) from None
        view = service.issue_grant(
            media_id=media_id,
            actor_id=claims["sub"],
            subject_type=subject_type,
            subject_id=body.subject_id,
            permission=permission,
            variant_scope=body.variant_scope,
            ttl_seconds=body.ttl_seconds,
            single_use=body.single_use,
            max_uses=body.max_uses,
            derived_from=body.derived_from,
        )
        return _grant_payload(view)

    @router.get("/media/platform/objects/{media_id}/grants")
    async def list_grants(
        media_id: str,
        claims: dict = Depends(current_claims),
        include_revoked: Annotated[bool, Query()] = False,
    ) -> dict:
        # Reading the grant list is an owner action; reuse the metadata read to enforce it.
        service.object_metadata(media_id, subject_id=claims["sub"])
        views = service.grants_for(media_id, include_revoked=include_revoked)
        return {"items": [_grant_payload(view) for view in views]}

    @router.delete("/media/platform/grants/{grant_id}")
    async def revoke_grant(
        grant_id: str,
        claims: dict = Depends(current_claims),
        reason: Annotated[str, Query(max_length=60)] = "owner_revoked",
    ) -> dict:
        view = service.revoke_grant(
            grant_id=grant_id, actor_id=claims["sub"], reason=reason
        )
        return _grant_payload(view)

    @router.post("/media/platform/objects/{media_id}/signed-urls")
    async def mint_signed_url(
        media_id: str,
        body: "SignedUrlRequest",
        claims: dict = Depends(current_claims),
    ) -> dict:
        try:
            variant_kind = VariantKind(body.variant_kind)
            tier = VisibilityTier(body.tier) if body.tier else None
        except ValueError:
            raise AppError(
                code="MEDIA_VARIANT_KIND_INVALID",
                message="媒体演绎版不合法",
                status_code=422,
            ) from None
        token, parsed = service.mint_signed_url(
            media_id=media_id,
            variant_kind=variant_kind,
            actor_id=claims["sub"],
            tier=tier,
            aud_scope=body.audience,
        )
        # Note: the effective TTL is decided by the server; the response states it so a
        # client can refresh before expiry instead of guessing.
        ttl_seconds = int((parsed.expires_at - datetime.now(timezone.utc)).total_seconds())
        return {
            "url": f"/api/v1/media/platform/content/{token}",
            "expires_at": parsed.expires_at.isoformat(),
            "ttl_seconds": max(0, ttl_seconds),
            "tier": parsed.tier.value,
            "variant_kind": parsed.variant_kind.value,
            "binding": {
                "media_id": parsed.media_id,
                "subject": parsed.subject if parsed.tier is VisibilityTier.PRIVATE else None,
                "audience": parsed.aud_scope,
                "single_use": parsed.single_use,
            },
        }

    @router.get("/media/platform/content/{token}")
    async def read_signed_content(
        token: str,
        authorization: Annotated[str | None, Header()] = None,
    ) -> Response:
        """Signed delivery.

        No auth *dependency* here on purpose: an ``audience`` URL must work for a member who
        was forwarded it (the frozen trade-off), while a ``private`` URL additionally
        requires the caller identity, which is why the optional bearer token is parsed
        manually instead of being required.
        """

        caller_id = _optional_subject(tokens, authorization)
        content = service.read_via_signed_token(token, caller_id=caller_id)
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
    # Moments integration (Phase 4.7): new upload path, legacy readers intact
    # ------------------------------------------------------------------ #
    @router.post("/media/platform/moments/attachments", status_code=201)
    async def attach_moment_media(
        request: Request,
        idempotency_key: Annotated[
            str, Header(alias="Idempotency-Key", min_length=1, max_length=128)
        ],
        file_name: Annotated[str, Query(max_length=255)] = "",
        mime: Annotated[str, Query(min_length=3, max_length=120)] = "image/jpeg",
        purpose: Annotated[str, Query(max_length=30)] = "MOMENT_IMAGE",
        claims: dict = Depends(current_claims),
    ) -> dict:
        if bridge is None:  # pragma: no cover - wiring guard
            raise AppError(
                code="MEDIA_MOMENTS_BRIDGE_UNAVAILABLE",
                message="朋友圈媒体桥不可用",
                status_code=503,
            )
        content = await request.body()
        attachment = bridge.attach(
            actor_id=claims["sub"],
            file_name=file_name,
            mime=(request.headers.get("content-type") or mime).split(";")[0].strip() or mime,
            content=content,
            idempotency_key=idempotency_key,
            purpose=purpose,
        )
        return {
            "media_id": attachment.media_id,
            "blob_id": attachment.blob_id,
            "upload_id": attachment.upload_id,
            "reference_id": attachment.reference_id,
            # The existing Moments publish endpoint accepts exactly this shape, so the
            # unchanged legacy path can carry platform-managed bytes.
            "capability_url": attachment.capability_url,
            "byte_size": attachment.byte_size,
            "mime": attachment.mime,
            "purpose": attachment.purpose,
            "reused": attachment.reused,
        }

    @router.post("/media/platform/releases")
    async def release_business_references(
        body: "BusinessReleaseRequest",
        claims: dict = Depends(current_claims),
        reason: Annotated[str, Query(max_length=32)] = ReleaseReason.MOMENT_DELETED.value,
    ) -> dict:
        """Release every platform reference of one business object owned by the caller.

        Used when a Moment (or a comment) is deleted: the bytes survive until the collector
        confirms nothing references them, so a delete can never take another reference's
        media with it.
        """

        try:
            business_type = BusinessType(body.business_type)
            parsed_reason = ReleaseReason(reason)
        except ValueError:
            raise AppError(
                code="MEDIA_REFERENCE_INVALID",
                message="业务引用不合法",
                status_code=422,
            ) from None
        released = service.references.release_for_business(
            business_type=business_type,
            business_id=body.business_id,
            reason=parsed_reason,
            actor_id=claims["sub"],
        )
        return {
            "released": [
                {
                    "reference_id": view.reference_id,
                    "media_id": view.media_id,
                    "business_type": view.business_type,
                    "business_id": view.business_id,
                }
                for view in released
            ]
        }

    @router.post("/media/platform/reconcile")
    async def reconcile_storage(
        dry_run: Annotated[bool, Query()] = True,
        _: None = Depends(require_maintenance),
    ) -> dict:
        """Storage/metadata reconciliation (readiness fix).

        Defaults to ``dry_run``: reporting is safe at any time, and enforcement is an explicit
        maintenance action. It never touches a file whose row is valid.
        """

        report = service.reconcile_storage(dry_run=dry_run)
        return report.as_dict()

    # ------------------------------------------------------------------ #
    # Diagnostics (maintenance gated)
    # ------------------------------------------------------------------ #
    @router.get("/media/platform/metrics")
    async def read_metrics(_: None = Depends(require_maintenance)) -> dict:
        return media_platform_metrics.snapshot()

    return router


def _may_pin(service, media_id: str, subject_id: str) -> bool:
    """Pinning is an owner action; a non-owner is rejected by the metadata read."""

    service.object_metadata(media_id, subject_id=subject_id)
    return True


def _optional_subject(tokens: TokenService, authorization: str | None) -> str | None:
    """Best-effort caller identity for the signed-content endpoint.

    A missing or malformed token is not an error here: ``private`` tokens reject on their
    own (subject mismatch), and ``audience`` tokens are deliberately usable without one.
    """

    if not authorization or not authorization.startswith("Bearer "):
        return None
    try:
        return tokens.decode_access_token(authorization[7:])["sub"]
    except Exception:
        return None


def _grant_payload(view) -> dict:
    return {
        "grant_id": view.grant_id,
        "media_id": view.media_id,
        "subject_type": view.subject_type,
        "subject_id": view.subject_id,
        "permission": view.permission,
        "variant_scope": list(view.variant_scope),
        "derived_from": view.derived_from,
        "grant_version": view.grant_version,
        "expires_at": view.expires_at,
        "single_use": view.single_use,
        "max_uses": view.max_uses,
        "uses": view.uses,
        "issued_by": view.issued_by,
        "revoked_at": view.revoked_at,
        "revoke_reason": view.revoke_reason,
    }


def _reference_payload(view) -> dict:
    return {
        "reference_id": view.reference_id,
        "media_id": view.media_id,
        "business_type": view.business_type,
        "business_id": view.business_id,
        "variant_kind": view.variant_kind,
        "room_ref": view.room_ref,
        "permission_scope": view.permission_scope,
        "ref_kind": view.ref_kind,
        "state": view.state,
        "created_at": view.created_at,
        "released_at": view.released_at,
        "release_reason": view.release_reason,
    }


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
