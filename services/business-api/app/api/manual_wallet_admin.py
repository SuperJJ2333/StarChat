"""Authenticated, audited read-only manual payout projections."""
import hashlib
import re
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Header, Path, Query, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

from app.core.errors import AppError
from app.modules.audit.writer import AuditWriter
from app.modules.identity.rbac import Permission, RbacService
from app.modules.identity.tokens import TokenService
from app.modules.wallet.finance_queries import WalletFinanceQuery


class PayoutReadModel(BaseModel):
    model_config = ConfigDict(strict=True, extra='forbid')


class ManualPayoutSummary(PayoutReadModel):
    id: str
    user_id: str
    quote_id: str
    amount: str = Field(pattern=r'^\d+\.\d{6}$')
    status: Literal['REQUESTED','CLAIMED','UNKNOWN','SETTLED','CANCELLED']
    digest: str
    candidate_txid: str | None
    settlement_txid: str | None
    review_reason: str | None
    claimed_by: str | None
    claimed_at: str | None
    created_at: str


class ManualPayoutSnapshot(PayoutReadModel):
    binding_id: str
    binding_version: int
    target_address: str
    official_address: str
    official_config_version: str
    owner_admin_id: str
    policy_version: str
    approval_policy: Literal['OWNER_MANUAL_V1']
    finality_policy: str
    network: str
    contract: str
    amount: str
    fee: Literal['0.000000']
    hold: str
    receive: str
    minimum: str
    max_per: str
    user_24h: str
    global_24h: str
    safety_epoch: int
    created_at: str
    expires_at: str
    # Multi-asset funding fields (2026-09 引入)；此前的历史报价快照没有这些键，
    # 只能为 None，财务审查按 USDT 单币种口径理解。
    funding_asset: Literal['USDT', 'CAIBI'] | None = None
    funding_amount: str | None = Field(default=None, pattern=r'^\d+\.\d{2,6}$')
    conversion_rate: str | None = Field(default=None, pattern=r'^\d+(\.\d+)?$')
    conversion_fee: str | None = Field(default=None, pattern=r'^\d+\.\d{6}$')
    cancellation_asset: Literal['USDT', 'CAIBI'] | None = None


class ManualPayoutCandidateRead(PayoutReadModel):
    txid: str
    actor_id: str | None
    reason_code: str
    created_at: str | None


class ManualPayoutDetail(ManualPayoutSummary):
    snapshot: ManualPayoutSnapshot
    candidates: list[ManualPayoutCandidateRead]


class ManualPayoutPage(PayoutReadModel):
    items: list[ManualPayoutSummary]
    next_cursor: str | None


def create_manual_wallet_admin_router(settings, session_factory):
    """Mount inside the existing /admin router. Contains only GET operations."""
    router = APIRouter(prefix='/wallet/manual/payouts',tags=['manual-wallet-admin'])
    tokens = TokenService(session_factory,
        jwt_secret=settings.jwt_secret or 'development-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer=settings.jwt_issuer,require_session_claims=True)
    rbac, audit, finance = RbacService(session_factory), AuditWriter(session_factory), WalletFinanceQuery(session_factory)

    def reader(authorization: Annotated[str | None, Header()] = None):
        if not authorization or not authorization.startswith('Bearer '):
            raise AppError(code='AUTH_REQUIRED',message='需要登录',status_code=401)
        actor = str(tokens.decode_access_token(authorization[7:])['sub'])
        if not rbac.permissions_for(actor).intersection({Permission.FINANCE_REVIEW,Permission.AUDIT_VIEW}):
            raise AppError(code='PERMISSION_DENIED',message='无权执行此操作',status_code=403)
        return actor

    def invalid_query():
        raise AppError(code='MANUAL_PAYOUT_QUERY_INVALID',message='提现查询参数无效',status_code=422)

    def query_keys(request,allowed):
        pairs = list(request.query_params.multi_items())
        if any(key not in allowed for key,_ in pairs) or len(pairs) != len({key for key,_ in pairs}):
            invalid_query()

    def read(operation,model,actor,request,subject):
        try:
            payload = operation()
        except ValueError:
            invalid_query()
        if payload is None:
            raise AppError(code='MANUAL_PAYOUT_NOT_FOUND',message='未找到提现记录',status_code=404)
        result = model.model_validate(payload)
        audit.record(actor_id=actor,subject_type='wallet_manual_payout',subject_id=subject,
            action='wallet.manual_payout.viewed',result='SUCCESS',reason_code='MANUAL_PAYOUT_VIEW',
            trace_id=getattr(request.state,'trace_id','manual-wallet-admin'))
        return JSONResponse(result.model_dump(),headers={'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'})

    @router.get('',response_model=ManualPayoutPage)
    def payouts(request: Request,actor: str = Depends(reader),limit: int = Query(50,ge=1,le=100),
                cursor: str | None = Query(None,min_length=1,max_length=100)):
        query_keys(request,{'limit','cursor'})
        raw_limit = request.query_params.get('limit')
        if raw_limit is not None and re.fullmatch('[1-9][0-9]{0,2}',raw_limit) is None:
            invalid_query()
        return read(lambda: finance.payouts(limit=limit,cursor=cursor),ManualPayoutPage,actor,request,'list')

    @router.get('/{order_id}',response_model=ManualPayoutDetail)
    def payout(request: Request,order_id: str = Path(min_length=1,max_length=36,pattern=r'^[A-Za-z0-9-]+$'),
               actor: str = Depends(reader)):
        query_keys(request,set())
        subject = hashlib.sha256(('manual-payout:'+order_id).encode()).hexdigest()
        return read(lambda: finance.payout(order_id),ManualPayoutDetail,actor,request,subject)

    return router
