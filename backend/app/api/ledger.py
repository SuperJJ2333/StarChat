from decimal import Decimal
from typing import Annotated

from fastapi import APIRouter, Depends, Header
from pydantic import BaseModel, ConfigDict, Field

from app.core.config import Settings
from app.core.errors import AppError
from app.modules.identity.rbac import Permission, RbacService
from app.modules.identity.tokens import TokenService
from app.modules.ledger.adjustments import AdjustmentWorkflow
from app.modules.ledger.service import LedgerService, PointTransferService

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

def create_ledger_router(settings: Settings, session_factory) -> APIRouter:
    router = APIRouter(prefix="/ledger", tags=["ledger"])
    ledger = LedgerService(session_factory)
    transfers = PointTransferService(ledger)
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

    @router.post("/transfers", status_code=201)
    def transfer(body: TransferRequest, idempotency_key: Annotated[str, Header(alias="Idempotency-Key")], user_id: str = Depends(actor)):
        result = transfers.transfer(sender_id=user_id, receiver_id=body.receiver_id, amount=body.amount, actor_id=user_id, reason_code="USER_TRANSFER", idempotency_key=idempotency_key)
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
