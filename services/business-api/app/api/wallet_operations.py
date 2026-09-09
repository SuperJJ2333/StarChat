"""Audited wallet operations. Production writes await real operational MFA/delivery."""
from datetime import date
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Header, Query, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

from app.api.wallet_report_contracts import DailyWalletReport
from app.core.errors import AppError
from app.modules.audit.writer import AuditWriter
from app.modules.identity.rbac import Permission, RbacService
from app.modules.identity.tokens import TokenService
from app.modules.wallet.closing import WalletClosingService
from app.modules.wallet.incidents import WalletIncidentService
from app.modules.wallet.monitoring import WalletMonitoringService


class CloseBody(BaseModel):
    model_config = ConfigDict(extra='forbid')
    day: date
    reason_code: str = Field(pattern=r'^[A-Z][A-Z0-9_]{2,99}$')


class IncidentCommandBody(BaseModel):
    model_config = ConfigDict(extra='forbid')
    reason_code: str = Field(pattern=r'^[A-Z][A-Z0-9_]{2,99}$')
    expected_version: int = Field(ge=1, strict=True)


class IncidentResolveBody(IncidentCommandBody):
    clearance_digest: str = Field(pattern=r'^[a-f0-9]{64}$')


class ClosedWalletReport(BaseModel):
    id: str
    day: date
    revision: int
    previous_id: str | None
    digest: str
    created_by: str
    created_at: str
    cutoff_kind: Literal['CAPTURED_ENTRY_SET']
    report: DailyWalletReport


class WalletIncidentView(BaseModel):
    id: str
    fingerprint: str
    code: str
    severity: Literal['P0', 'P1']
    subject_id: str
    status: Literal['OPEN', 'ACKNOWLEDGED', 'RESOLVED']
    generation: int
    version: int
    condition_active: bool
    opened_at: str
    last_seen_at: str
    cleared_at: str | None
    acknowledged_at: str | None
    resolved_at: str | None
    acknowledged_by: str | None
    resolved_by: str | None
    clearance_digest: str | None
    last_escalation_slot: int


class WalletIncidentList(BaseModel):
    items: list[WalletIncidentView]
    next_cursor: str | None


class WalletMonitorStatus(BaseModel):
    last_attempt_at: str | None
    last_success_at: str | None
    last_error_code: str | None
    stale: bool
    stale_after_seconds: int
    external_delivery_configured: bool


def create_wallet_operations_router(settings, factory, wallet_service):
    router = APIRouter(prefix='/wallet', tags=['wallet-operations'])
    tokens = TokenService(factory, jwt_secret=settings.jwt_secret or 'development-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer=settings.jwt_issuer, require_session_claims=True)
    rbac = RbacService(factory)
    audit = AuditWriter(factory)
    closes = WalletClosingService(factory)
    incidents = WalletIncidentService(factory)
    monitor = WalletMonitoringService(factory, wallet_service=wallet_service if wallet_service.provider is not None else None)

    def finance(authorization: Annotated[str | None, Header()] = None):
        if not authorization or not authorization.startswith('Bearer '):
            raise AppError(code='AUTH_REQUIRED', message='需要登录', status_code=401)
        user = str(tokens.decode_access_token(authorization[7:])['sub'])
        if Permission.SYSTEM_ADMIN not in rbac.permissions_for(user):
            rbac.require(user, Permission.FINANCE_REVIEW)
        return user

    def command(user: str = Depends(finance), authorization: Annotated[str | None, Header()] = None):
        if settings.environment == 'production':
            raise AppError(code='WALLET_OPERATIONS_NOT_READY', message='生产操作尚未接入完整复核及告警设施', status_code=503)
        tokens.require_recent_login(authorization[7:])
        return user

    def response(payload):
        return JSONResponse(payload, headers={'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff'})

    def read(payload, user, subject, request):
        audit.record(actor_id=user, subject_type='wallet_operations', subject_id=subject,
            action='wallet.operations.viewed', result='SUCCESS', reason_code='WALLET_OPERATIONS_VIEW',
            trace_id=getattr(request.state, 'trace_id', 'wallet-operations'))
        return response(payload)

    @router.post('/reports/close', response_model=ClosedWalletReport)
    def close(body: CloseBody,
              idempotency_key: Annotated[str, Header(alias='Idempotency-Key', min_length=1, max_length=128)],
              user: str = Depends(command)):
        try:
            return response(closes.close(body.day, actor_id=user, reason_code=body.reason_code, idempotency_key=idempotency_key))
        except OverflowError as exc:
            raise AppError(code='WALLET_REPORT_TOO_LARGE', message='日结证据超出上限', status_code=413) from exc
        except ValueError as exc:
            raise AppError(code='WALLET_CLOSE_INVALID', message='日结日期或证据无效', status_code=422) from exc

    @router.get('/reports/closed/{id}', response_model=ClosedWalletReport)
    def closed(id: str, request: Request, user: str = Depends(finance)):
        return read(closes.get(id), user, id, request)

    @router.get('/incidents', response_model=WalletIncidentList)
    def listing(request: Request, user: str = Depends(finance), limit: int = Query(50, ge=1, le=100),
                cursor: str | None = Query(None, max_length=128)):
        return read(incidents.list_incidents(limit=limit, cursor=cursor), user, 'incidents', request)

    @router.get('/incidents/{id}', response_model=WalletIncidentView)
    def incident(id: str, request: Request, user: str = Depends(finance)):
        return read(incidents.get(id), user, id, request)

    @router.post('/incidents/{id}/ack', response_model=WalletIncidentView)
    def ack(id: str, body: IncidentCommandBody,
            idempotency_key: Annotated[str, Header(alias='Idempotency-Key', min_length=1, max_length=128)],
            user: str = Depends(command)):
        return response(incidents.ack(id, actor_id=user, idempotency_key=idempotency_key, **body.model_dump()))

    @router.post('/incidents/{id}/resolve', response_model=WalletIncidentView)
    def resolve(id: str, body: IncidentResolveBody,
                idempotency_key: Annotated[str, Header(alias='Idempotency-Key', min_length=1, max_length=128)],
                user: str = Depends(command)):
        replay = incidents.replay_resolve(id, actor_id=user, idempotency_key=idempotency_key, **body.model_dump())
        if replay is not None:
            return response(replay)
        if not monitor.run_once()['complete']:
            raise AppError(code='WALLET_MONITOR_UNAVAILABLE', message='当前证据扫描失败，不能结案', status_code=503)
        return response(incidents.resolve(id, actor_id=user, idempotency_key=idempotency_key, **body.model_dump()))

    @router.get('/monitor/status', response_model=WalletMonitorStatus)
    def status(request: Request, user: str = Depends(finance)):
        return read(monitor.status(), user, 'monitor', request)

    return router
