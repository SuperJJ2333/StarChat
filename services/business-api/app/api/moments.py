from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Header, Query, Response
from pydantic import BaseModel, ConfigDict, Field

from app.core.config import Settings
from app.core.errors import AppError
from app.modules.identity.tokens import TokenService
from app.modules.moments.service import MomentsService
from app.modules.moments.media import MomentMediaService


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class CreateMoment(Strict):
    text: str = Field(default="", max_length=5000)
    visibility: Literal["PUBLIC", "FRIENDS", "INCLUDE", "EXCLUDE", "SELF"]
    image_urls: list[str] = Field(default_factory=list, max_length=9)
    include_user_ids: list[str] = Field(default_factory=list)
    exclude_user_ids: list[str] = Field(default_factory=list)
    location: str | None = None
    link_url: str | None = None


class Comment(Strict):
    text: str = Field(min_length=1, max_length=1000)
    parent_id: str | None = None


class Preferences(Strict):
    history_range: Literal["ALL", "SIX_MONTHS", "ONE_MONTH", "THREE_DAYS"]
    personalized_recommendations: bool


class Report(Strict):
    reason_code: str = Field(min_length=1, max_length=100)

class BeginUpload(Strict):
    file_name: str = Field(min_length=1, max_length=255)
    mime_type: str = Field(min_length=1, max_length=100)
    byte_size: int = Field(gt=0)


def create_moments_router(settings: Settings, factory):
    router = APIRouter(prefix="/moments", tags=["moments"])
    service = MomentsService(factory)
    media = MomentMediaService(factory)
    tokens = TokenService(factory, jwt_secret=settings.jwt_secret or "development-jwt-secret-at-least-thirty-two-bytes", jwt_issuer=settings.jwt_issuer)

    def actor(authorization: Annotated[str | None, Header()] = None):
        if not authorization or not authorization.startswith("Bearer "):
            raise AppError(code="AUTH_REQUIRED", message="需要登录", status_code=401)
        return str(tokens.decode_access_token(authorization[7:])["sub"])

    @router.post("", status_code=201)
    def create(body: CreateMoment, idempotency_key: Annotated[str, Header(alias="Idempotency-Key")], user=Depends(actor)):
        row = service.create(user, body.model_dump(), idempotency_key)
        return service.detail(user, row.id)

    @router.get("/feed")
    def feed(mode: Literal["recommended", "latest"] = "recommended", user=Depends(actor)):
        return {"items": service.feed(user, mode=mode), "next_cursor": None, "mode": mode}

    @router.get("/search")
    def search(q: Annotated[str, Query(min_length=1, max_length=100)], user=Depends(actor)):
        return {"items": service.feed(user, q=q), "next_cursor": None}

    @router.get("/preferences")
    def preferences(user=Depends(actor)):
        return service.preferences(user)

    @router.put("/preferences")
    def update_preferences(body: Preferences, user=Depends(actor)):
        return service.preferences(user, body.model_dump())

    @router.post("/media/uploads", status_code=201)
    def begin_upload(body: BeginUpload, idempotency_key: Annotated[str, Header(alias="Idempotency-Key")], user=Depends(actor)):
        row = media.begin(user, body.file_name, body.mime_type, body.byte_size, idempotency_key)
        return {"id": row.id, "upload_url": f"/api/v1/moments/media/uploads/{row.id}/content", "expires_at": row.expires_at}

    @router.post("/media/uploads/{upload_id}/complete")
    def complete_upload(upload_id: str, idempotency_key: Annotated[str, Header(alias="Idempotency-Key")], user=Depends(actor)):
        row = media.complete(user, upload_id)
        return {"id": row.id, "status": row.status, "media_url": f"media://{row.object_key}"}

    @router.get("/{moment_id}")
    def detail(moment_id: str, user=Depends(actor)):
        return service.detail(user, moment_id)

    @router.delete("/{moment_id}", status_code=204)
    def delete(moment_id: str, idempotency_key: Annotated[str, Header(alias="Idempotency-Key")], user=Depends(actor)):
        service.delete(user, moment_id, idempotency_key)
        return Response(status_code=204)

    @router.post("/{moment_id}/likes", status_code=201)
    def like(moment_id: str, idempotency_key: Annotated[str, Header(alias="Idempotency-Key")], user=Depends(actor)):
        row = service.like(user, moment_id, idempotency_key)
        return {"id": row.id}

    @router.delete("/{moment_id}/likes", status_code=204)
    def unlike(moment_id: str, idempotency_key: Annotated[str, Header(alias="Idempotency-Key")], user=Depends(actor)):
        service.unlike(user, moment_id, idempotency_key)
        return Response(status_code=204)

    @router.post("/{moment_id}/comments", status_code=201)
    def comment(moment_id: str, body: Comment, idempotency_key: Annotated[str, Header(alias="Idempotency-Key")], user=Depends(actor)):
        row = service.comment(user, moment_id, body.text, body.parent_id, idempotency_key)
        return service.comment_dto(row)

    @router.delete("/{moment_id}/comments/{comment_id}", status_code=204)
    def delete_comment(moment_id: str, comment_id: str, idempotency_key: Annotated[str, Header(alias="Idempotency-Key")], user=Depends(actor)):
        service.delete_comment(user, moment_id, comment_id, idempotency_key)
        return Response(status_code=204)

    @router.post("/{moment_id}/reports", status_code=201)
    def report(moment_id: str, body: Report, idempotency_key: Annotated[str, Header(alias="Idempotency-Key")], user=Depends(actor)):
        row = service.report(user, moment_id, body.reason_code, idempotency_key)
        return {"id": row.id, "status": row.status}

    return router
