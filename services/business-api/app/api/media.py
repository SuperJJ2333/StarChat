"""业务域媒体压缩接口（非 E2EE 聊天媒体专用）。"""

from typing import Annotated
from uuid import uuid4

from fastapi import APIRouter, Depends, Header, Query, Request, Response

from app.core.config import Settings
from app.core.errors import AppError
from app.core.rate_limits import RateLimiter
from app.integrations.private_storage import LocalPrivateObjectStorage
from app.modules.identity.tokens import TokenService
from app.modules.media import images as media_images

MEDIA_RENDITION_URL_TTL = 300


def create_media_router(
    settings: Settings,
    session_factory,
    rate_limiter: RateLimiter,
    *,
    storage: LocalPrivateObjectStorage,
) -> APIRouter:
    router = APIRouter(tags=["media"])
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

    @router.post("/media/images/compress")
    async def compress_image(
        request: Request,
        sizes: str | None = Query(default=None),
        format: str = Query(default="webp"),
        claims: dict = Depends(current_claims),
    ) -> dict:
        content = await request.body()
        if len(content) > settings.media_max_upload_bytes:
            raise AppError(
                code="MEDIA_TOO_LARGE",
                message="图片超过大小限制",
                status_code=413,
            )
        content_type = (request.headers.get("content-type") or "").split(";")[0].strip()
        spec = media_images.compress_renditions(
            content,
            content_type=content_type,
            sizes=media_images.parse_sizes(sizes),
            output_format=format,
        )
        user_id = claims["sub"]
        rate_limiter.hit(
            f"media:compress:{user_id}", limit=30, window_seconds=60
        )
        media_id = str(uuid4())
        items = []
        for rendition in spec.renditions:
            object_key = (
                f"media/renders/{media_id}/{rendition.size}{rendition.extension}"
            )
            storage.put(object_key, rendition.content)
            token = storage.sign_key(object_key)
            items.append(
                {
                    "size": rendition.size,
                    "width": rendition.width,
                    "height": rendition.height,
                    "format": rendition.format,
                    "byte_size": len(rendition.content),
                    "url": (
                        f"/api/v1/media/images/content/"
                        f"{token}?expires_in={MEDIA_RENDITION_URL_TTL}"
                    ),
                }
            )
        return {
            "media_id": media_id,
            "source": {
                "width": spec.source_width,
                "height": spec.source_height,
                "format": spec.source_format,
                "byte_size": len(content),
            },
            "items": items,
        }

    @router.get("/media/images/content/{token}", include_in_schema=False)
    async def read_media_content(token: str, expires_in: int) -> Response:
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
