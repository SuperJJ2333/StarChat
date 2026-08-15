from datetime import datetime
from typing import Annotated

from fastapi import APIRouter, Depends, Header, Request, Response
from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.core.config import Settings
from app.core.errors import AppError
from app.integrations.private_storage import LocalPrivateObjectStorage, PrivateObjectStorage
from app.modules.identity.profile import MAX_AVATAR_BYTES, ProfileResult, ProfileService
from app.modules.identity.tokens import TokenService


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class ProfilePatch(StrictModel):
    nickname: str | None = Field(default=None, max_length=64)
    signature: str | None = Field(default=None, max_length=140)

    @field_validator("nickname")
    @classmethod
    def nickname_cannot_be_null(cls, value: str | None) -> str:
        if value is None:
            raise ValueError("nickname cannot be null")
        return value


class ProfileResponse(BaseModel):
    username: str
    nickname: str
    signature: str | None
    masked_email: str
    avatar_url: str | None
    avatar_fallback_seed: str
    profile_updated_at: datetime


class AvatarUploadRequest(StrictModel):
    mime_type: str = Field(min_length=1, max_length=64)
    byte_size: int = Field(gt=0)


class AvatarUploadResponse(BaseModel):
    upload_id: str
    upload_url: str
    expires_at: datetime


def create_profile_router(
    settings: Settings,
    session_factory,
    *,
    storage: PrivateObjectStorage,
) -> APIRouter:
    router = APIRouter(tags=["profile"])
    tokens = TokenService(
        session_factory,
        jwt_secret=settings.jwt_secret or "development-jwt-secret-at-least-thirty-two-bytes",
        jwt_issuer=settings.jwt_issuer,
        require_session_claims=settings.environment != "test",
    )
    profiles = ProfileService(session_factory, storage=storage)

    def current_claims(
        authorization: Annotated[str | None, Header()] = None,
    ) -> dict:
        if not authorization or not authorization.startswith("Bearer "):
            raise AppError(code="AUTH_REQUIRED", message="需要登录", status_code=401)
        return tokens.decode_access_token(authorization[7:])

    def request_context(request: Request) -> tuple[str, str | None]:
        return (
            getattr(request.state, "trace_id", "unknown"),
            request.client.host if request.client else None,
        )

    @router.get("/profile/me", response_model=ProfileResponse)
    async def get_profile(claims: dict = Depends(current_claims)) -> ProfileResult:
        return profiles.get(claims["sub"])

    @router.patch("/profile/me", response_model=ProfileResponse)
    async def update_profile(
        body: ProfilePatch,
        request: Request,
        idempotency_key: Annotated[
            str,
            Header(alias="Idempotency-Key", min_length=1, max_length=128),
        ],
        claims: dict = Depends(current_claims),
    ) -> ProfileResult:
        trace_id, source_ip = request_context(request)
        return profiles.update(
            claims["sub"],
            body.model_dump(exclude_unset=True),
            idempotency_key=idempotency_key,
            trace_id=trace_id,
            source_ip=source_ip,
        )

    @router.post(
        "/profile/avatar/uploads",
        response_model=AvatarUploadResponse,
        status_code=201,
    )
    async def begin_avatar_upload(
        body: AvatarUploadRequest,
        idempotency_key: Annotated[
            str,
            Header(alias="Idempotency-Key", min_length=1, max_length=128),
        ],
        claims: dict = Depends(current_claims),
    ) -> AvatarUploadResponse:
        upload = profiles.begin_avatar_upload(
            claims["sub"],
            mime_type=body.mime_type,
            byte_size=body.byte_size,
            idempotency_key=idempotency_key,
        )
        return AvatarUploadResponse(
            upload_id=upload.id,
            upload_url=f"/api/v1/profile/avatar/uploads/{upload.id}/content",
            expires_at=upload.expires_at,
        )

    @router.put("/profile/avatar/uploads/{upload_id}/content", status_code=204)
    async def put_avatar_content(
        upload_id: str,
        request: Request,
        content_type: Annotated[str | None, Header(alias="Content-Type")] = None,
        claims: dict = Depends(current_claims),
    ) -> Response:
        content_buffer = bytearray()
        async for chunk in request.stream():
            if len(content_buffer) + len(chunk) > MAX_AVATAR_BYTES:
                raise AppError(
                    code="AVATAR_SIZE_EXCEEDED",
                    message="头像不得超过 5 MiB",
                    status_code=422,
                )
            content_buffer.extend(chunk)
        content = bytes(content_buffer)
        profiles.put_avatar_content(
            claims["sub"],
            upload_id,
            content_type=(content_type or "").partition(";")[0].strip().casefold(),
            content=content,
        )
        return Response(status_code=204)

    @router.post(
        "/profile/avatar/uploads/{upload_id}/complete",
        response_model=ProfileResponse,
    )
    async def complete_avatar_upload(
        upload_id: str,
        request: Request,
        idempotency_key: Annotated[
            str,
            Header(alias="Idempotency-Key", min_length=1, max_length=128),
        ],
        claims: dict = Depends(current_claims),
    ) -> ProfileResult:
        trace_id, source_ip = request_context(request)
        return profiles.complete_avatar_upload(
            claims["sub"],
            upload_id,
            idempotency_key=idempotency_key,
            trace_id=trace_id,
            source_ip=source_ip,
        )

    @router.delete("/profile/avatar/uploads/{upload_id}", status_code=204)
    async def cancel_avatar_upload(
        upload_id: str,
        claims: dict = Depends(current_claims),
    ) -> Response:
        profiles.cancel_avatar_upload(claims["sub"], upload_id)
        return Response(status_code=204)

    @router.delete("/profile/avatar", status_code=204)
    async def delete_avatar(
        request: Request,
        idempotency_key: Annotated[
            str,
            Header(alias="Idempotency-Key", min_length=1, max_length=128),
        ],
        claims: dict = Depends(current_claims),
    ) -> Response:
        trace_id, source_ip = request_context(request)
        profiles.delete_avatar(
            claims["sub"],
            idempotency_key=idempotency_key,
            trace_id=trace_id,
            source_ip=source_ip,
        )
        return Response(status_code=204)

    @router.get(
        "/profile/avatar/content/{token}",
        include_in_schema=False,
    )
    async def read_avatar(token: str, expires_in: int) -> Response:
        if not isinstance(storage, LocalPrivateObjectStorage):
            raise AppError(
                code="AVATAR_URL_INVALID",
                message="头像链接无效或已过期",
                status_code=404,
            )
        content, mime_type = storage.read_signed(token, expires_in)
        return Response(
            content=content,
            media_type=mime_type,
            headers={
                "Cache-Control": "private, no-store",
                "Referrer-Policy": "no-referrer",
                "X-Content-Type-Options": "nosniff",
            },
        )

    return router
