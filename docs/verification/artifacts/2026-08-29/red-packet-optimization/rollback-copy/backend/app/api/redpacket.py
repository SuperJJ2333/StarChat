from datetime import datetime, timedelta, timezone
from decimal import Decimal
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Header
from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.core.config import Settings
from app.core.errors import AppError
from app.modules.identity.rbac import Permission, RbacService
from app.modules.identity.tokens import TokenService
from app.modules.ledger.service import LedgerService
from app.modules.redpacket.service import RedPacketService

class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")

class CreateRedPacketRequest(StrictModel):
    mode: Literal["EQUAL", "RANDOM"]
    total: Decimal = Field(gt=0, decimal_places=2)
    share_count: int = Field(ge=1, le=500)
    room_id: str | None = Field(default=None, max_length=255)
    recipient_id: str | None = Field(default=None, max_length=36)

    @model_validator(mode="after")
    def one_destination(self):
        if bool(self.room_id) == bool(self.recipient_id):
            raise ValueError("exactly one destination is required")
        return self

class CancelRequest(StrictModel):
    reason_code: str = Field(min_length=1, max_length=100)

def create_redpacket_router(settings: Settings, session_factory) -> APIRouter:
    router = APIRouter(prefix="/red-packets", tags=["red-packets"])
    service = RedPacketService(session_factory, LedgerService(session_factory))
    rbac = RbacService(session_factory)
    tokens = TokenService(session_factory, jwt_secret=settings.jwt_secret or "development-jwt-secret-at-least-thirty-two-bytes", jwt_issuer=settings.jwt_issuer, require_session_claims=settings.environment != "test")

    def actor(authorization: Annotated[str | None, Header()] = None) -> str:
        if not authorization or not authorization.startswith("Bearer "):
            raise AppError(code="AUTH_REQUIRED", message="需要登录", status_code=401)
        return str(tokens.decode_access_token(authorization[7:])["sub"])

    @router.post("", status_code=201)
    def create(body: CreateRedPacketRequest, idempotency_key: Annotated[str, Header(alias="Idempotency-Key")], user_id: str = Depends(actor)):
        kwargs = dict(sender_id=user_id, total=body.total, share_count=body.share_count, room_id=body.room_id, recipient_id=body.recipient_id, idempotency_key=idempotency_key, expires_at=datetime.now(timezone.utc) + timedelta(hours=24))
        packet = service.create_equal(**kwargs) if body.mode == "EQUAL" else service.create_random(**kwargs)
        return {"id": packet.id, "mode": packet.mode, "asset": "CAIBI", "total": str(packet.total), "share_count": packet.share_count, "expires_at": packet.expires_at}

    @router.post("/{packet_id}/claims", status_code=201)
    def claim(packet_id: str, idempotency_key: Annotated[str, Header(alias="Idempotency-Key")], user_id: str = Depends(actor)):
        share = service.claim(packet_id, user_id=user_id, idempotency_key=idempotency_key)
        return {"share_id": share.id, "amount": str(share.amount), "asset": "CAIBI"}

    @router.get("/{packet_id}")
    def detail(packet_id: str, user_id: str = Depends(actor)):
        return service.detail(packet_id, user_id=user_id)

    @router.post("/{packet_id}/cancel")
    def cancel(packet_id: str, body: CancelRequest, idempotency_key: Annotated[str, Header(alias="Idempotency-Key")], user_id: str = Depends(actor)):
        rbac.require(user_id, Permission.RED_PACKET_CANCEL)
        packet = service.cancel_unclaimed(packet_id, actor_id=user_id, reason_code=body.reason_code, idempotency_key=idempotency_key)
        return {"id": packet.id, "status": packet.status}

    return router
