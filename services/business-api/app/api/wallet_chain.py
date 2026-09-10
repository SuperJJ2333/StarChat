"""Authenticated, audited access to read-only chain observation evidence."""
import hashlib
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Header, Path, Query, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from app.core.errors import AppError
from app.integrations.tron.admin_query import ChainWatchQuery, ChainWatchUnavailable
from app.modules.audit.writer import AuditWriter
from app.modules.identity.rbac import Permission, RbacService
from app.modules.identity.tokens import TokenService
from app.modules.wallet.finance_queries import WalletFinanceQuery


class PlatformRecord(BaseModel):
    kind: Literal['DEPOSIT', 'PAYOUT']
    record_id: str
    ledger_status: Literal['REVIEW', 'CREDITED', 'SETTLED']
    user_id: str | None
    ledger_transaction_id: str | None
    intent_id: str | None
    reason_code: str
    evidence_status: Literal['VERIFIED', 'UNVERIFIED', 'CONFLICT']
    attribution_status: str | None = None
    attribution_reason_text: str | None = None
    user_username: str | None = None
    user_nickname: str | None = None


class ChainTransaction(BaseModel):
    txid: str = Field(pattern=r'^[a-fA-F0-9]{64}$')
    log_index: int
    timestamp_ms: int
    block_number: int
    amount: str = Field(pattern=r'^\d+\.\d{6}$')
    net_amount: str = Field(pattern=r'^-?\d+\.\d{6}$')
    direction: Literal['INFLOW', 'UNMATCHED_OUTFLOW']
    era: Literal['HISTORICAL', 'LIVE']
    asset: Literal['USDT']
    network: Literal['TRON']
    user_attribution: Literal['UNVERIFIED', 'VERIFIED']
    ledger_status: Literal['NOT_EVALUATED', 'REVIEW', 'CREDITED', 'SETTLED']
    platform_record: PlatformRecord | None = None
    watch_only: Literal[True]


class ChainTransactionDetail(ChainTransaction):
    from_address: str
    to_address: str


class ChainTransactionPage(BaseModel):
    items: list[ChainTransaction]
    total: int
    limit: int
    offset: int
    snapshot: int


class ChainSummary(BaseModel):
    source: Literal['TRONGRID_SINGLE_SOURCE']
    network: Literal['TRON']
    asset: Literal['USDT']
    watch_only: Literal[True]
    financial_writes_enabled: Literal[False]
    user_attribution: Literal['UNVERIFIED']
    independent_verification: Literal[False]
    coverage_complete: Literal[False]
    coverage_meaning: Literal['SOURCE_TRAVERSAL_ONLY']
    coverage_start_ms: int
    live_started_ms: int
    checkpoint_ms: int
    heartbeat_ms: int | None
    last_success_ms: int | None
    lag_ms: int
    freshness_ms: int | None
    observer_status: Literal['OK', 'ERROR', 'NOT_STARTED']
    reconciliation: Literal['SOURCE_MATCHED', 'BALANCE_DISCREPANCY', 'RECONCILIATION_UNVERIFIED']
    balance: str | None
    total: int


def create_wallet_chain_router(settings, session_factory, database_path=None):
    router = APIRouter(prefix='/wallet/chain', tags=['wallet-chain'])
    service = ChainWatchQuery(database_path if database_path is not None else
                             getattr(settings, 'tron_observer_database_path', None))
    tokens = TokenService(session_factory,
                          jwt_secret=settings.jwt_secret or 'development-jwt-secret-at-least-thirty-two-bytes',
                          jwt_issuer=settings.jwt_issuer, require_session_claims=True)
    rbac = RbacService(session_factory)
    audit = AuditWriter(session_factory)
    finance = WalletFinanceQuery(session_factory)

    def reader(authorization: Annotated[str | None, Header()] = None):
        if not authorization or not authorization.startswith('Bearer '):
            raise AppError(code='AUTH_REQUIRED', message='需要登录', status_code=401)
        actor = str(tokens.decode_access_token(authorization[7:])['sub'])
        if not rbac.permissions_for(actor).intersection({Permission.FINANCE_REVIEW, Permission.AUDIT_VIEW}):
            raise AppError(code='PERMISSION_DENIED', message='无权执行此操作', status_code=403)
        return actor

    def read(operation, actor, request, subject):
        try:
            payload = operation()
        except ChainWatchUnavailable:
            raise AppError(code='CHAIN_WATCH_UNAVAILABLE', message='链上观察数据暂不可用', status_code=503) from None
        if payload is None:
            raise AppError(code='CHAIN_TRANSACTION_NOT_FOUND', message='未找到链上观察记录', status_code=404)
        items = payload.get('items', []) if 'items' in payload else [payload] if 'txid' in payload else []
        for item in items:
            link = finance.chain_link(item['txid'], item['log_index'])
            item['platform_record'] = link
            if link is not None:
                item['ledger_status'] = link['ledger_status']
                item['user_attribution'] = 'VERIFIED' if link['user_id'] else 'UNVERIFIED'
        audit.record(actor_id=actor, subject_type='wallet_chain', subject_id=subject,
                     action='wallet.chain.viewed', result='SUCCESS', reason_code='CHAIN_WATCH_VIEW',
                     trace_id=getattr(request.state, 'trace_id', 'wallet-chain'))
        return JSONResponse(payload, headers={'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff'})

    @router.get('/summary', response_model=ChainSummary)
    def summary(request: Request, actor: str = Depends(reader)):
        return read(service.summary, actor, request, 'summary')

    @router.get('/transactions', response_model=ChainTransactionPage)
    def transactions(request: Request, actor: str = Depends(reader), limit: int = Query(50, ge=1, le=100),
                     offset: int = Query(0, ge=0, le=1_000_000),
                     snapshot: int | None = Query(None, ge=0, le=9223372036854775807),
                     direction: Literal['INFLOW', 'UNMATCHED_OUTFLOW'] | None = None,
                     start_ms: int | None = Query(None, ge=0, le=253402300799999),
                     end_ms: int | None = Query(None, ge=0, le=253402300799999),
                     txid: str | None = Query(None, pattern=r'^[a-fA-F0-9]{64}$')):
        if start_ms is not None and end_ms is not None and start_ms > end_ms:
            raise AppError(code='CHAIN_QUERY_INVALID', message='查询日期范围无效', status_code=422)
        return read(lambda: service.transactions(limit=limit, offset=offset, direction=direction,
                                                 start_ms=start_ms, end_ms=end_ms, txid=txid, snapshot=snapshot),
                    actor, request, 'transactions')

    @router.get('/transactions/{txid}/{log_index}', response_model=ChainTransactionDetail)
    def detail(request: Request, txid: str = Path(pattern=r'^[a-fA-F0-9]{64}$'),
               log_index: int = Path(ge=0, le=2147483647), actor: str = Depends(reader)):
        subject = hashlib.sha256(f'TRON:{txid.lower()}:{log_index}'.encode('ascii')).hexdigest()
        return read(lambda: service.detail(txid, log_index), actor, request, subject)

    return router
