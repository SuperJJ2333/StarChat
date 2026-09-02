from datetime import datetime, timedelta, timezone
from decimal import Decimal
from typing import Annotated

from fastapi import APIRouter, Depends, Header
from pydantic import BaseModel, ConfigDict, Field

from app.core.config import Settings
from app.core.errors import AppError
from app.modules.identity.tokens import TokenService
from app.modules.ledger.service import LedgerService
from app.modules.transfer.service import ChatTransferService


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class CreateChatTransferRequest(StrictModel):
    receiver_id: str = Field(min_length=1, max_length=36)
    amount: Decimal = Field(gt=0, decimal_places=2)
    note: str | None = Field(default=None, max_length=64)
    room_id: str | None = Field(default=None, max_length=255)


def create_transfer_router(settings: Settings, session_factory) -> APIRouter:
    router = APIRouter(prefix="/chat-transfers", tags=["chat-transfers"])
    service = ChatTransferService(session_factory, LedgerService(session_factory))
    tokens = TokenService(session_factory, jwt_secret=settings.jwt_secret or "development-jwt-secret-at-least-thirty-two-bytes", jwt_issuer=settings.jwt_issuer, require_session_claims=settings.environment != "test")

    def actor(authorization: Annotated[str | None, Header()] = None) -> str:
        if not authorization or not authorization.startswith("Bearer "):
            raise AppError(code="AUTH_REQUIRED", message="需要登录", status_code=401)
        return str(tokens.decode_access_token(authorization[7:])["sub"])

    @router.post("", status_code=201)
    def create(body: CreateChatTransferRequest, idempotency_key: Annotated[str, Header(alias="Idempotency-Key")], user_id: str = Depends(actor)):
        try:
            transfer = service.create(sender_id=user_id, receiver_id=body.receiver_id, amount=body.amount, note=body.note, room_id=body.room_id, idempotency_key=idempotency_key, expires_at=datetime.now(timezone.utc) + timedelta(hours=24))
        except ValueError as error:
            if str(error) == "insufficient balance":
                raise AppError(code="CHAT_TRANSFER_BALANCE_INSUFFICIENT", message="转账失败，账户余额不足", status_code=422) from error
            raise
        return service.snapshot(transfer)

    @router.post("/{transfer_id}/accept")
    def accept(transfer_id: str, idempotency_key: Annotated[str, Header(alias="Idempotency-Key")], user_id: str = Depends(actor)):
        try:
            transfer = service.accept(transfer_id, user_id=user_id, idempotency_key=idempotency_key)
        except ValueError as error:
            raise _translate(error) from error
        return service.snapshot(transfer)

    @router.post("/{transfer_id}/decline")
    def decline(transfer_id: str, idempotency_key: Annotated[str, Header(alias="Idempotency-Key")], user_id: str = Depends(actor)):
        try:
            transfer = service.decline(transfer_id, user_id=user_id, reason_code="CHAT_TRANSFER_DECLINED", idempotency_key=idempotency_key)
        except ValueError as error:
            raise _translate(error) from error
        return service.snapshot(transfer)

    @router.get("/{transfer_id}")
    def detail(transfer_id: str, user_id: str = Depends(actor)):
        try:
            return service.detail(transfer_id, user_id=user_id)
        except ValueError as error:
            raise _translate(error) from error

    return router


def _translate(error: ValueError) -> AppError:
    message = str(error)
    if message == "transfer not found" or message == "transfer is not visible to this user":
        return AppError(code="CHAT_TRANSFER_NOT_FOUND", message="转账不存在", status_code=404)
    if message == "only the recipient can operate this transfer":
        return AppError(code="CHAT_TRANSFER_FORBIDDEN", message="只有收款方可以操作该转账", status_code=403)
    return AppError(code="CHAT_TRANSFER_UNAVAILABLE", message="转账当前不可操作", status_code=409)
