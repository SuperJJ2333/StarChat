from datetime import datetime
from decimal import Decimal
from typing import Annotated

from fastapi import APIRouter, Depends, Header, Query, Response
from pydantic import AwareDatetime, BaseModel, ConfigDict, Field

from app.core.config import Settings
from app.core.errors import AppError
from app.modules.identity.rbac import Permission, RbacService
from app.modules.identity.tokens import TokenService
from app.modules.identity.payment_pin import PaymentPinService
from app.modules.ledger.adjustments import AdjustmentWorkflow
from app.modules.ledger.service import LedgerService, PointTransferService
from app.modules.ledger.statements import StatementService

class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")

class TransferRequest(StrictModel):
    receiver_id: str = Field(min_length=1, max_length=36)
    amount: Decimal = Field(gt=0, decimal_places=2)

class AdjustmentRequestBody(StrictModel):
    user_id: str = Field(min_length=1, max_length=36)
    amount: Decimal = Field(decimal_places=2)
    reason_code: str = Field(min_length=1, max_length=100)

class ReviewBody(StrictModel):
    approve: bool

class PolicyBody(StrictModel):
    per_transaction: Decimal = Field(gt=0, decimal_places=2)
    per_day: Decimal = Field(gt=0, decimal_places=2)
    allowed_users: set[str]

class StatementItem(StrictModel):
    id: str
    asset: str
    amount: str
    kind: str
    reason_code: str
    created_at: datetime
    reversal_of_id: str | None
    status: str | None
    note: str | None
    business_id: str | None
    transfer_amount: str | None
    fee: str | None
    accepted_at: datetime | None
    transfer_created_at: datetime | None
    counterparty_id: str | None = None
    packet_mode: str | None = None
    packet_room: str | None = None

class StatementPage(StrictModel):
    items: list[StatementItem]
    next_cursor: str | None

def create_ledger_router(settings: Settings, session_factory) -> APIRouter:
    router = APIRouter(prefix="/ledger", tags=["ledger"])
    ledger = LedgerService(session_factory)
    statements = StatementService(session_factory)
    transfers = PointTransferService(ledger)
    payment_pin = PaymentPinService(session_factory, require_all=settings.payment_pin_require_all)
    workflow = AdjustmentWorkflow(session_factory, ledger, admin_threshold=Decimal(str(getattr(settings, "adjustment_admin_threshold", "10000.00"))))
    rbac = RbacService(session_factory)
    tokens = TokenService(session_factory, jwt_secret=settings.jwt_secret or "development-jwt-secret-at-least-thirty-two-bytes", jwt_issuer=settings.jwt_issuer, require_session_claims=settings.environment != "test")

    def actor(authorization: Annotated[str | None, Header()] = None) -> str:
        if not authorization or not authorization.startswith("Bearer "):
            raise AppError(code="AUTH_REQUIRED", message="需要登录", status_code=401)
        return str(tokens.decode_access_token(authorization[7:])["sub"])

    @router.get("/balances/me")
    def balance(user_id: str = Depends(actor)):
        return {"asset": "CAIBI", "balance": str(ledger.balance(user_id))}

    @router.get("/transactions/me", response_model=StatementPage)
    def my_transactions(response: Response, kind: Annotated[str | None, Query(pattern="^(redpacket|transfer|withdrawal|deposit|other)$")] = None,
                        start_at: AwareDatetime | None = None, end_at: AwareDatetime | None = None,
                        q: Annotated[str | None, Query(max_length=100)] = None,
                        cursor: Annotated[str | None, Query(max_length=256)] = None, limit: Annotated[int, Query(ge=1, le=100)] = 50,
                        user_id: str = Depends(actor)):
        response.headers["Cache-Control"] = "private, no-store"
        if start_at and end_at and start_at >= end_at:
            raise AppError(code="LEDGER_STATEMENT_INVALID_RANGE", message="账单时间范围无效", status_code=422)
        try:
            return statements.list(user_id=user_id, kind=kind, start_at=start_at, end_at=end_at, q=q.strip() if q else None, cursor=cursor, limit=limit)
        except ValueError as error:
            raise AppError(code="LEDGER_STATEMENT_INVALID_CURSOR", message="账单游标无效", status_code=422) from error

    @router.get("/transactions/me/{transaction_id}", response_model=StatementItem)
    def my_transaction(transaction_id: str, response: Response, user_id: str = Depends(actor)):
        response.headers["Cache-Control"] = "private, no-store"
        item = statements.get(user_id=user_id, transaction_id=transaction_id)
        if item is None:
            raise AppError(code="LEDGER_STATEMENT_NOT_FOUND", message="账单不存在", status_code=404)
        return item

    @router.post("/transfers", status_code=201)
    def transfer(body: TransferRequest, idempotency_key: Annotated[str, Header(alias="Idempotency-Key")], user_id: str = Depends(actor)):
        with session_factory.begin() as session:
            payment_pin.reject_legacy(session, user_id=user_id)
            result = transfers.transfer(sender_id=user_id, receiver_id=body.receiver_id, amount=body.amount, actor_id=user_id, reason_code="USER_TRANSFER", idempotency_key=idempotency_key, session=session)
        return {"transaction_id": result.transaction.id, "asset": "CAIBI", "amount": str(body.amount), "fee": str(result.fee)}

    @router.put("/adjustment-policies/{actor_id}", status_code=204)
    def set_policy(actor_id: str, body: PolicyBody, user_id: str = Depends(actor)):
        rbac.require(user_id, Permission.SYSTEM_ADMIN)
        workflow.set_policy(actor_id, per_transaction=body.per_transaction, per_day=body.per_day, allowed_users=body.allowed_users)

    @router.post("/adjustments", status_code=201)
    def submit(body: AdjustmentRequestBody, idempotency_key: Annotated[str, Header(alias="Idempotency-Key")], user_id: str = Depends(actor)):
        rbac.require(user_id, Permission.SYSTEM_ADMIN)
        return workflow.submit(actor_id=user_id, user_id=body.user_id, amount=body.amount, reason_code=body.reason_code, idempotency_key=idempotency_key)

    @router.post("/adjustments/{request_id}/finance-review")
    def finance_review(request_id: str, body: ReviewBody, user_id: str = Depends(actor)):
        rbac.require(user_id, Permission.SYSTEM_ADMIN)
        return workflow.finance_review(request_id, reviewer_id=user_id, approve=body.approve)

    @router.post("/adjustments/{request_id}/admin-review")
    def admin_review(request_id: str, body: ReviewBody, user_id: str = Depends(actor)):
        rbac.require(user_id, Permission.SYSTEM_ADMIN)
        return workflow.admin_review(request_id, reviewer_id=user_id, approve=body.approve)

    @router.post("/adjustments/{request_id}/execute")
    def execute(request_id: str, idempotency_key: Annotated[str, Header(alias="Idempotency-Key")], user_id: str = Depends(actor)):
        rbac.require(user_id, Permission.SYSTEM_ADMIN)
        return workflow.execute(request_id, actor_id=user_id, idempotency_key=idempotency_key)

    return router
