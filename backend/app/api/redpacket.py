from datetime import datetime, timedelta, timezone
from decimal import Decimal
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Header
from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.core.config import Settings
from app.core.errors import AppError
from app.modules.identity.rbac import Permission, RbacService
from app.modules.identity.tokens import TokenService
from app.modules.ledger.service import LedgerService, money
from app.modules.redpacket.service import RedPacketService
from app.modules.settings.service import RED_PACKET_MAX_TOTAL_KEY, SettingService

class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")

class CreateRedPacketRequest(StrictModel):
    mode: Literal["EQUAL", "RANDOM", "EXCLUSIVE"]
    total: Decimal = Field(gt=0, decimal_places=2)
    share_count: int = Field(ge=1, le=500)
    room_id: str | None = Field(default=None, max_length=255)
    recipient_id: str | None = Field(default=None, max_length=36)

    @model_validator(mode="after")
    def destination_matches_mode(self):
        if self.mode == "EXCLUSIVE":
            if not self.room_id or not self.recipient_id:
                raise ValueError("exclusive red packet requires room_id and recipient_id")
            if self.share_count != 1:
                raise ValueError("exclusive red packet requires share_count=1")
        elif bool(self.room_id) == bool(self.recipient_id):
            raise ValueError("exactly one destination is required")
        return self

class CancelRequest(StrictModel):
    reason_code: str = Field(min_length=1, max_length=100)

def create_redpacket_router(settings: Settings, session_factory, *, avatar_storage=None) -> APIRouter:
    router = APIRouter(prefix="/red-packets", tags=["red-packets"])
    service = RedPacketService(session_factory, LedgerService(session_factory), max_total=settings.red_packet_max_total)
    if avatar_storage is not None:
        from app.modules.identity.profile import ProfileService

        # 领取详情需要展示领取人/发送人的用户名与自定义头像。
        service.profiles = ProfileService(session_factory, storage=avatar_storage)
    app_settings = SettingService(session_factory)
    rbac = RbacService(session_factory)
    tokens = TokenService(session_factory, jwt_secret=settings.jwt_secret or "development-jwt-secret-at-least-thirty-two-bytes", jwt_issuer=settings.jwt_issuer, require_session_claims=settings.environment != "test")

    def resolve_max_total() -> str:
        return app_settings.get(RED_PACKET_MAX_TOTAL_KEY, default=settings.red_packet_max_total) or settings.red_packet_max_total

    def actor(authorization: Annotated[str | None, Header()] = None) -> str:
        if not authorization or not authorization.startswith("Bearer "):
            raise AppError(code="AUTH_REQUIRED", message="需要登录", status_code=401)
        return str(tokens.decode_access_token(authorization[7:])["sub"])

    @router.post("", status_code=201)
    def create(body: CreateRedPacketRequest, idempotency_key: Annotated[str, Header(alias="Idempotency-Key")], user_id: str = Depends(actor)):
        max_total = resolve_max_total()
        service.max_total = money(max_total)
        kwargs = dict(sender_id=user_id, total=body.total, share_count=body.share_count, room_id=body.room_id, recipient_id=body.recipient_id, idempotency_key=idempotency_key, expires_at=datetime.now(timezone.utc) + timedelta(hours=24))
        try:
            packet = service.create_equal(**kwargs) if body.mode == "EQUAL" else service.create_random(**kwargs) if body.mode == "RANDOM" else service.create_exclusive(**kwargs)
        except ValueError as error:
            if str(error) == "insufficient balance":
                raise AppError(code="RED_PACKET_BALANCE_INSUFFICIENT", message="红包创建失败，账户余额不足", status_code=422) from error
            if str(error) == "RED_PACKET_LIMIT_EXCEEDED":
                raise AppError(code="RED_PACKET_LIMIT_EXCEEDED", message=f"单个红包金额不能超过 {max_total} 点钻", status_code=422) from error
            raise
        return {"id": packet.id, "mode": packet.mode, "asset": "CAIBI", "total": str(packet.total), "share_count": packet.share_count, "expires_at": packet.expires_at}

    @router.get("/limits")
    def limits(user_id: str = Depends(actor)):
        return {"asset": "CAIBI", "max_total": str(money(resolve_max_total())), "max_share_count": 500, "min_per_share": "0.01"}

    @router.post("/{packet_id}/claims", status_code=201)
    def claim(packet_id: str, idempotency_key: Annotated[str, Header(alias="Idempotency-Key")], user_id: str = Depends(actor)):
        try:
            share = service.claim(packet_id, user_id=user_id, idempotency_key=idempotency_key)
        except ValueError as error:
            message = str(error)
            if message == "recipient mismatch":
                raise AppError(code="RED_PACKET_RECIPIENT_MISMATCH", message="只有指定成员可以领取该红包", status_code=403) from error
            if message in ("user already claimed",):
                raise AppError(code="RED_PACKET_ALREADY_CLAIMED", message="已领取过该红包", status_code=409) from error
            raise AppError(code="RED_PACKET_UNAVAILABLE", message="红包当前不可领取", status_code=409) from error
        return {"share_id": share.id, "amount": str(share.amount), "asset": "CAIBI"}

    @router.get("/{packet_id}")
    def detail(packet_id: str, user_id: str = Depends(actor)):
        try:
            return service.detail(packet_id, user_id=user_id)
        except ValueError as error:
            if str(error) == "recipient mismatch":
                raise AppError(code="RED_PACKET_FORBIDDEN", message="无权查看该红包", status_code=403) from error
            raise AppError(code="RED_PACKET_NOT_FOUND", message="红包不存在", status_code=404) from error

    @router.post("/{packet_id}/cancel")
    def cancel(packet_id: str, body: CancelRequest, idempotency_key: Annotated[str, Header(alias="Idempotency-Key")], user_id: str = Depends(actor)):
        rbac.require(user_id, Permission.RED_PACKET_CANCEL)
        packet = service.cancel_unclaimed(packet_id, actor_id=user_id, reason_code=body.reason_code, idempotency_key=idempotency_key)
        return {"id": packet.id, "status": packet.status}

    return router
