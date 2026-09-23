"""ADR-0077：人工充值 API（用户申请 + 客服处理 + 目录）。"""
from decimal import Decimal
from datetime import datetime, timezone
from typing import Annotated, Literal
from uuid import uuid4

from fastapi import APIRouter, Depends, Header
from pydantic import BaseModel, ConfigDict, Field

from app.core.config import Settings
from app.core.errors import AppError
from app.modules.identity.rbac import Permission, RbacService
from app.modules.identity.tokens import TokenService
from app.modules.identity.support_order_auth import SupportOrderSessionAuthorizer
from app.modules.recharge.service import RechargeService
from app.modules.recharge.notifications import SupportOrderNotifications  # model registration


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class RechargeSubmitBody(StrictModel):
    amount_usdt: str = Field(pattern=r"^(0|[1-9][0-9]{0,15})(\.[0-9]{1,6})?$", max_length=24)
    evidence_txid: str | None = Field(default=None, min_length=10, max_length=64)
    note: str | None = Field(default=None, max_length=200)


class RechargeRejectBody(StrictModel):
    reason: str = Field(min_length=3, max_length=200)
    claim_token: str | None = Field(default=None, max_length=128)


class RechargeCreditBody(StrictModel):
    ledger_transaction_id: str = Field(min_length=1, max_length=36)
    final_caibi_amount: str = Field(pattern=r"^(0|[1-9][0-9]{0,15})(\.[0-9]{1,2})?$", max_length=20)
    final_rate: str | None = Field(default=None, pattern=r"^(0|[1-9][0-9]{0,8})(\.[0-9]{1,6})?$", max_length=18)
    adjustment_id: str | None = Field(default=None, min_length=1, max_length=36)


class RechargeReviewBody(StrictModel):
    action: str = Field(pattern='^(retry|release)$')
    binding_id: str = Field(min_length=1, max_length=36)
    reason: str | None = Field(default=None, min_length=3, max_length=200)
    claim_token: str | None = Field(default=None, max_length=128)


class RechargeBindBody(StrictModel):
    adjustment_id: str = Field(min_length=1, max_length=36)
    final_rate: str | None = Field(default=None, pattern=r"^(0|[1-9][0-9]{0,8})(\.[0-9]{1,6})?$", max_length=18)
    claim_token: str | None = Field(default=None, max_length=128)


class RechargeClaimBody(StrictModel):
    review: bool = False
    reason: str | None = Field(default=None, min_length=3, max_length=200)


class RechargeLeaseBody(StrictModel):
    claim_token: str | None = Field(default=None, max_length=128)


class RechargeEvidenceBody(StrictModel):
    txid: str = Field(pattern=r'^[a-fA-F0-9]{64}$')


class RechargeVerifyBody(RechargeEvidenceBody):
    claim_token: str = Field(min_length=1, max_length=128)
    log_index: int = Field(ge=0)


class RechargeSettlementBody(RechargeLeaseBody):
    final_rate: str = Field(pattern=r'^(0|[1-9][0-9]{0,8})(\.[0-9]{1,6})?$', max_length=18)


class CsDirectoryBody(StrictModel):
    cs_user_id: str = Field(min_length=1, max_length=36)
    display_name: str = Field(min_length=1, max_length=64)
    payment_address: str = Field(min_length=20, max_length=128)
    note: str | None = Field(default=None, max_length=200)
    enabled: bool = True
    sort: int = Field(default=0, ge=0, le=1000)


IdempotencyKey = Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128)]


def create_recharge_router(settings: Settings, session_factory, *, recharge_service: RechargeService) -> APIRouter:
    router = APIRouter(prefix="/recharge", tags=["recharge"])
    tokens = TokenService(session_factory,
        jwt_secret=settings.jwt_secret or "development-jwt-secret-at-least-thirty-two-bytes",
        jwt_issuer=settings.jwt_issuer, require_session_claims=settings.environment != "test")
    rbac = RbacService(session_factory)
    order_access = SupportOrderSessionAuthorizer(settings, session_factory,
        lambda: datetime.now(timezone.utc))

    def command_authorization(authorization: Annotated[str | None, Header()] = None):
        if not authorization or not authorization.startswith('Bearer '):
            raise AppError(code='AUTH_REQUIRED', message='需要管理会话', status_code=401)
        claims = tokens.decode_access_token(authorization[7:])
        # Match the established fixture-only boundary. Real test sessions are
        # still subject to the live management-session and activation requirements.
        if settings.environment == 'test' and not claims.get('family_id'):
            return None
        order_access.require(claims=claims)
        return order_access.authorization(claims=claims)

    def actor(authorization: Annotated[str | None, Header()] = None) -> str:
        if not authorization or not authorization.startswith("Bearer "):
            raise AppError(code="AUTH_REQUIRED", message="需要登录", status_code=401)
        return str(tokens.decode_access_token(authorization[7:])["sub"])

    def require_finance(actor_id: str) -> str:
        rbac.require(actor_id, Permission.FINANCE_REVIEW)
        return actor_id

    @router.get("/directory")
    def directory(user_id: str = Depends(actor)):
        """官方充值客服目录（后台授权，APP 据此推荐）。"""
        return {"items": recharge_service.directory(), "disclaimer": "参考估算，最终以客服结算为准"}

    @router.get('/official-payment')
    def official_payment(user_id: str = Depends(actor)):
        return recharge_service.official_payment_view()

    @router.post("/requests", status_code=201)
    def submit(body: RechargeSubmitBody, idempotency_key: IdempotencyKey, user_id: str = Depends(actor)):
        if settings.environment != 'test':
            recharge_service.official_payment_view()
        return recharge_service.submit(user_id=user_id, amount_usdt=Decimal(body.amount_usdt),
            evidence_txid=body.evidence_txid, note=body.note, idempotency_key=idempotency_key)

    @router.get("/requests/mine")
    def mine(user_id: str = Depends(actor)):
        return {"items": recharge_service.list_mine(user_id=user_id)}

    @router.post("/requests/{request_id}/cancel", response_model=None)
    def cancel(request_id: str, user_id: str = Depends(actor)):
        return recharge_service.cancel(user_id=user_id, request_id=request_id)

    @router.post('/requests/{request_id}/evidence')
    def evidence(request_id: str, body: RechargeEvidenceBody, idempotency_key: IdempotencyKey,
                 user_id: str = Depends(actor)):
        return recharge_service.submit_evidence(request_id=request_id, user_id=user_id,
            txid=body.txid, idempotency_key=idempotency_key)

    @router.post('/admin/requests/{request_id}/claim')
    def claim(request_id: str, body: RechargeClaimBody, idempotency_key: IdempotencyKey,
              actor_id: str = Depends(actor), authorization=Depends(command_authorization)):
        require_finance(actor_id)
        return recharge_service.claim_order(request_id=request_id, actor_id=actor_id,
            idempotency_key=idempotency_key, authorization=authorization, **body.model_dump())

    @router.post('/admin/requests/{request_id}/heartbeat')
    def heartbeat(request_id: str, body: RechargeLeaseBody, actor_id: str = Depends(actor),
                  authorization=Depends(command_authorization)):
        require_finance(actor_id)
        return recharge_service.heartbeat_order(request_id=request_id, actor_id=actor_id,
            claim_token=body.claim_token, authorization=authorization)

    @router.post('/admin/requests/{request_id}/verify-payment')
    def verify_payment(request_id: str, body: RechargeVerifyBody, idempotency_key: IdempotencyKey,
                       actor_id: str = Depends(actor), authorization=Depends(command_authorization)):
        require_finance(actor_id)
        return recharge_service.verify_order_payment(request_id=request_id, actor_id=actor_id,
            idempotency_key=idempotency_key, authorization=authorization, **body.model_dump())

    @router.get("/admin/requests/pending", dependencies=[Depends(command_authorization)])
    def pending(cursor: str | None = None, limit: int = 50,
                scope: Literal['all', 'mine'] = 'all', actor_id: str = Depends(actor)):
        require_finance(actor_id)
        return recharge_service.pending_page(cursor=cursor, limit=limit,
            claimed_by=actor_id if scope == 'mine' else None)

    @router.get('/admin/events', dependencies=[Depends(command_authorization)])
    def events(cursor: str | None = None, limit: int = 50, actor_id: str = Depends(actor)):
        require_finance(actor_id)
        return recharge_service.order_events(actor_id=actor_id, cursor=cursor, limit=limit)

    @router.post('/admin/requests/{request_id}/prepare-settlement')
    def prepare_settlement(request_id: str, body: RechargeSettlementBody, idempotency_key: IdempotencyKey,
                           actor_id: str = Depends(actor), authorization=Depends(command_authorization)):
        require_finance(actor_id)
        return recharge_service.prepare_settlement(request_id=request_id, actor_id=actor_id,
            idempotency_key=idempotency_key, authorization=authorization, **body.model_dump())

    @router.post('/admin/requests/{request_id}/execute-settlement')
    def execute_settlement(request_id: str, body: RechargeLeaseBody, idempotency_key: IdempotencyKey,
                           actor_id: str = Depends(actor), authorization=Depends(command_authorization)):
        require_finance(actor_id)
        return recharge_service.execute_settlement(request_id=request_id, actor_id=actor_id,
            claim_token=body.claim_token, idempotency_key=idempotency_key, authorization=authorization)

    @router.post("/admin/requests/{request_id}/reject")
    def reject(request_id: str, body: RechargeRejectBody, idempotency_key: IdempotencyKey, actor_id: str = Depends(actor), authorization=Depends(command_authorization)):
        require_finance(actor_id)
        return recharge_service.reject(request_id=request_id, actor_id=actor_id, reason=body.reason,
            idempotency_key=idempotency_key, claim_token=body.claim_token, authorization=authorization)

    @router.post("/admin/requests/{request_id}/credit")
    def credit(request_id: str, body: RechargeCreditBody, idempotency_key: IdempotencyKey, actor_id: str = Depends(actor), authorization=Depends(command_authorization)):
        """财务调整执行成功后登记 CREDITED（入账本身走既有公开财务服务）。"""
        require_finance(actor_id)
        return recharge_service.mark_credited(request_id=request_id, actor_id=actor_id,
            ledger_transaction_id=body.ledger_transaction_id,
            final_caibi_amount=Decimal(body.final_caibi_amount),
            final_rate=Decimal(body.final_rate) if body.final_rate else None,
            adjustment_id=body.adjustment_id, idempotency_key=idempotency_key, authorization=authorization)

    @router.get("/admin/requests", dependencies=[Depends(command_authorization)])
    def admin_requests(status: str | None = None, cursor: str | None = None,
                       limit: int = 50, actor_id: str = Depends(actor)):
        require_finance(actor_id)
        return recharge_service.admin_requests(status=status, cursor=cursor, limit=limit)

    @router.get("/admin/review-queue", dependencies=[Depends(command_authorization)])
    def review_queue(cursor: str | None = None, limit: int = 50, actor_id: str = Depends(actor)):
        require_finance(actor_id)
        return recharge_service.review_queue_page(cursor=cursor, limit=limit)

    @router.get("/admin/requests/{request_id}/timeline", dependencies=[Depends(command_authorization)])
    def timeline(request_id: str, actor_id: str = Depends(actor)):
        require_finance(actor_id)
        return recharge_service.case_timeline(request_id=request_id)

    @router.post("/admin/requests/{request_id}/review")
    def review(request_id: str, body: RechargeReviewBody, idempotency_key: IdempotencyKey,
               actor_id: str = Depends(actor), authorization=Depends(command_authorization)):
        """待核对处置：retry=只读核实重新登记（幂等）；release=确证未执行后释放
        （服务端核证拒绝且未执行或已冲正；记录缺失不能证明未入账）。"""
        require_finance(actor_id)
        if body.action == "retry":
            try:
                return recharge_service.retry_review_registration(request_id=request_id, actor_id=actor_id,
                    expected_binding_id=body.binding_id, claim_token=body.claim_token, authorization=authorization)
            except AppError as error:
                if error.code in ('RECHARGE_PROOF_INVALID', 'RECHARGE_SETTLEMENT_MISMATCH',
                        'RECHARGE_FINAL_RATE_REQUIRED'):
                    return {'status': 'NEEDS_REVIEW', 'binding_state': 'NEEDS_REVIEW',
                        'reason_code': error.code}
                raise
        if body.action == "release":
            return recharge_service.release_review_binding(request_id=request_id,
                actor_id=actor_id, reason=body.reason or "", idempotency_key=idempotency_key,
                expected_binding_id=body.binding_id, claim_token=body.claim_token, authorization=authorization)
        raise AppError(code='RECHARGE_REVIEW_ACTION_INVALID', message='处置动作无效', status_code=422)

    @router.post("/admin/requests/{request_id}/bind")
    def bind(request_id: str, body: RechargeBindBody, idempotency_key: IdempotencyKey, actor_id: str = Depends(actor), authorization=Depends(command_authorization)):
        """把案件绑定到唯一授权财务调整（执行走既有公开财务审批链路）。"""
        require_finance(actor_id)
        return recharge_service.bind_finance_adjustment(request_id=request_id,
            adjustment_id=body.adjustment_id, actor_id=actor_id, idempotency_key=idempotency_key,
            final_rate=Decimal(body.final_rate) if body.final_rate is not None else None, claim_token=body.claim_token, authorization=authorization)

    @router.post("/admin/requests/{request_id}/complete-binding")
    def complete_binding(request_id: str, body: RechargeLeaseBody | None = None, actor_id: str = Depends(actor),
                         authorization=Depends(command_authorization)):
        """执行后的幂等登记（worker 兜底的手动入口；复用全部凭证校验）。"""
        require_finance(actor_id)
        return recharge_service.complete_bound(request_id=request_id, actor_id=actor_id,
            claim_token=body.claim_token if body else None, authorization=authorization)

    @router.get("/admin/reserve-valuation")
    def reserve_valuation(actor_id: str = Depends(actor)):
        """ADR-0076 三类数量一次读齐：点钻账面 / 参考估值 / 实际 USDT 义务。"""
        from app.modules.identity.rbac import Permission

        rbac.require(actor_id, Permission.SYSTEM_ADMIN)
        from app.modules.ledger.reserve import reserve_valuation_snapshot

        with session_factory() as session:
            snapshot = reserve_valuation_snapshot(session)
        return {key: (str(value) if value is not None else None)
            for key, value in snapshot.items()}

    @router.get('/admin/directory')
    def admin_directory(actor_id: str = Depends(actor)):
        rbac.require(actor_id, Permission.SYSTEM_ADMIN)
        return {'items': recharge_service.directory(include_disabled=True)}

    @router.put("/admin/directory")
    def upsert_directory(body: CsDirectoryBody, actor_id: str = Depends(actor)):
        rbac.require(actor_id, Permission.SYSTEM_ADMIN)
        return recharge_service.upsert_directory_entry(actor_id=actor_id, entry_id=None, **body.model_dump())

    @router.put("/admin/directory/{entry_id}")
    def update_directory(entry_id: str, body: CsDirectoryBody, actor_id: str = Depends(actor)):
        rbac.require(actor_id, Permission.SYSTEM_ADMIN)
        return recharge_service.upsert_directory_entry(actor_id=actor_id, entry_id=entry_id, **body.model_dump())

    return router
