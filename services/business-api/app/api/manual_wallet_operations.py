"""Owner-authenticated incident review; closing an incident never resumes funds."""
from datetime import datetime, timezone
import hashlib
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Header, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, SecretStr

from app.api.wallet_operations import WalletIncidentView
from app.api.admin_wallet_auth import AdminWalletProofBody, selected_password_authorization
from app.core.errors import AppError, FieldError
from app.integrations.tron import diagnostics as diag
from app.modules.wallet.manual_diagnostics import current_diagnostics, safe_review_result
from app.modules.identity.tokens import TokenService
from app.modules.identity.wallet_access import require_wallet_actor, require_wallet_session
from app.modules.ledger.reserve import lock_budget
from app.modules.wallet.incidents import WalletIncidentService
from app.modules.wallet.models import WalletControl
from app.modules.wallet.manual_control import ManualWalletControl


class ManualReviewBody(AdminWalletProofBody):
    model_config = ConfigDict(extra='forbid')
    expected_version: int = Field(ge=1, strict=True)
    reason_code: str = Field(pattern=r'^[A-Z][A-Z0-9_]{2,99}$')


class ManualResolveBody(ManualReviewBody):
    clearance_digest: str = Field(pattern=r'^[a-f0-9]{64}$')


class ManualControlBody(AdminWalletProofBody):
    model_config = ConfigDict(extra='forbid')
    expected_epoch: int = Field(ge=0, strict=True)
    snapshot_digest: str = Field(pattern=r'^[a-f0-9]{64}$')
    reason_code: str = Field(pattern=r'^[A-Z][A-Z0-9_]{2,99}$')


class ManualControlView(BaseModel):
    epoch: int
    snapshot_digest: str
    reserve_version: int | None
    withdrawals_paused: bool
    global_restricted: bool
    outgoing_restricted: bool
    restriction_scopes: list[str]
    unresolved_incidents: int
    status: str


class ManualDiagnosticView(BaseModel):
    checked_at: datetime
    source_status: Literal['HEALTHY', 'WAITING', 'UNAVAILABLE', 'UNHEALTHY']
    coverage_status: Literal['CURRENT', 'WAITING', 'UNAVAILABLE', 'CONFLICT']
    observation_id: int | None
    heartbeat_at: datetime | None
    codes: list[str]
    reserve_policy: Literal['manual_liquidity', 'full_backing']


def create_manual_wallet_operations_router(settings, factory, *, reviewer=None, mfa_verifier=None, activation_monitor=None):
    router = APIRouter(prefix='/wallet/manual/operations', tags=['manual-wallet-operations'])
    tokens = TokenService(factory, jwt_secret=settings.jwt_secret or 'development-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer=settings.jwt_issuer, require_session_claims=True)
    incidents = WalletIncidentService(factory)
    clock = lambda: datetime.now(timezone.utc)

    def fail(code, message, status=409):
        raise AppError(code=code, message=message, status_code=status)

    def actor(authorization: Annotated[str | None, Header()] = None):
        if not authorization or not authorization.startswith('Bearer '):
            fail('AUTH_REQUIRED', '需要登录', 401)
        claims = tokens.decode_access_token(authorization[7:])
        if getattr(settings, 'wallet_real_mode', 'disabled') != 'manual_tron':
            fail('MANUAL_OPERATIONS_UNAVAILABLE', '人工钱包复核尚未配置', 503)
        user = str(claims['sub'])
        if user != settings.wallet_manual_owner_admin_id:
            fail('PERMISSION_DENIED', '仅官方钱包管理员可复核', 403)
        with factory.begin() as session:
            require_wallet_actor(session, user_id=user, clock=clock, administrator=True)
        tokens.require_recent_login(authorization[7:])
        return claims

    def verify(identity, body, request):
        authorization = selected_password_authorization(settings, factory, clock, identity, body)
        if authorization is not None:
            return authorization
        proof = body.mfa_proof
        verifier = mfa_verifier
        if verifier is None:
            from app.modules.identity.totp import FernetSecretProtector, TotpService
            from app.modules.wallet.binding_adapters import WalletTotpVerifier
            key = getattr(settings, 'wallet_totp_encryption_key', None)
            limiter = getattr(request.app.state, 'rate_limiter', None)
            if key is None or limiter is None:
                fail('WALLET_MFA_NOT_CONFIGURED', '动态验证尚未配置', 503)
            verifier = WalletTotpVerifier(TotpService(factory, protector=FernetSecretProtector(
                key.get_secret_value().encode('ascii'))), limiter, clock=clock)
        if verifier(user_id=identity['sub'], session_id=identity['family_id'], proof=proof.get_secret_value(), now=clock()) is not True:
            fail('TOTP_REQUIRED', '需要重新验证动态验证码', 403)
        return clock()

    def scope(id):
        row = incidents.get(id)
        if not row['fingerprint'].startswith(('manual-reserve:', 'manual-liquidity:')) or row['subject_id'] != 'global':
            fail('WALLET_INCIDENT_MANUAL_SCOPE_REQUIRED', '此事件不属于人工钱包监控范围')
        return row

    def build_monitor():
        from app.integrations.tron.funding_source import SQLiteFundingSource
        from app.modules.wallet.funding import OfficialFundingConfig
        from app.modules.wallet.manual_reserve_monitor import ManualReserveMonitor
        from app.modules.wallet.monitoring import WalletMonitoringService
        official = OfficialFundingConfig(settings.wallet_official_address.get_secret_value(), settings.wallet_official_config_version)
        source = SQLiteFundingSource(settings.tron_observer_database_path, official_address=official.address,
            clock=clock, solid_head_max_age_seconds=180)
        delivery = WalletMonitoringService(factory).status()['external_delivery_configured']
        monitor = ManualReserveMonitor(factory, source=source, official_config=official,
            activation_baseline_time=settings.wallet_funding_baseline_at,
            activation_baseline_height=settings.wallet_funding_baseline_height, clock=clock,
            external_delivery_configured=delivery)
        monitor.reserve_policy = getattr(settings, 'wallet_reserve_policy', 'full_backing')
        from app.modules.wallet.manual_discovery_sync import discovery_sync
        monitor.discovery_sync = discovery_sync(factory, source=source, official_config=official,
            baseline_time=settings.wallet_funding_baseline_at,
            baseline_height=settings.wallet_funding_baseline_height, clock=clock)
        return monitor

    @diag.traced('manual_monitor')
    def review(on_review, *, incident_id):
        result = reviewer(on_review=on_review) if reviewer is not None else build_monitor().review_once(on_review=on_review)
        if not result.get('complete'):
            status, codes = safe_review_result(result)
            for code in codes:
                diag.emit('WARNING' if status in ('WAITING','RETRY') else 'ERROR',
                    'incident_review_incomplete', component='manual_monitor', incident_id=incident_id,
                    reason_code=code, status=status)
            raise AppError(code='WALLET_MONITOR_UNAVAILABLE',
                message='当前检查未完成，事故尚未结案，资金保持暂停。', status_code=503,
                fields=[FieldError(loc=['monitor'], type='wallet.monitor.status', msg=status)] +
                    [FieldError(loc=['monitor'], type='wallet.monitor.reason', msg=code) for code in codes])
        diag.emit('INFO', 'incident_review_completed', component='manual_monitor', incident_id=incident_id,
                  status='REVIEWED')
        return result['result']

    def guard(identity, verified_at):
        def authorize(session):
            # Same ordering as manual settlement and monitor completion. These
            # locks and the identity checks use the caller's single connection.
            lock_budget(session)
            session.get(WalletControl, 'global', with_for_update=True)
            if (settings.wallet_real_mode != 'manual_tron'
                    or identity['sub'] != settings.wallet_manual_owner_admin_id):
                fail('PERMISSION_DENIED', '仅官方钱包管理员可复核', 403)
            require_wallet_actor(session, user_id=identity['sub'], clock=clock, administrator=True)
            if callable(verified_at):
                return verified_at(session)
            session_fresh = require_wallet_session(session, claims=identity, clock=clock, verified_at=verified_at)
            def fresh():
                if getattr(settings,'wallet_admin_auth_mode','totp') != 'totp':
                    fail('ADMIN_WALLET_AUTH_MODE_MISMATCH','管理员验证方式已变更',403)
                session_fresh()
            fresh()
            return fresh
        return authorize

    def response(value):
        return JSONResponse(value, headers={'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'})

    def controls():
        if activation_monitor is not None:
            identity = ':'.join((activation_monitor.source.source_identity, activation_monitor.config.version,
                activation_monitor.baseline.isoformat(), str(activation_monitor.baseline_height)))
        else:
            identity = ':'.join((settings.wallet_official_address.get_secret_value(), settings.wallet_official_config_version,
                settings.wallet_funding_baseline_at.isoformat(), str(settings.wallet_funding_baseline_height)))
        identity += ':' + getattr(settings, 'wallet_reserve_policy', 'full_backing')
        control = ManualWalletControl(factory, clock=clock,
            configuration_id=hashlib.sha256(identity.encode()).hexdigest())
        control.reserve_policy = getattr(settings, 'wallet_reserve_policy', 'full_backing')
        return control

    class LazyActivationMonitor:
        def activate_once(self, **kwargs):
            return build_monitor().activate_once(**kwargs)

    @router.get('/control', response_model=ManualControlView)
    def control_status(identity=Depends(actor)):
        return response(controls().status())

    @router.get('/diagnostics', response_model=ManualDiagnosticView)
    def diagnostics(identity=Depends(actor)):
        policy = getattr(settings, 'wallet_reserve_policy', 'full_backing')
        policy = policy if policy in ('manual_liquidity', 'full_backing') else 'full_backing'
        try:
            monitor = activation_monitor or build_monitor()
            value = current_diagnostics(factory, monitor.source, monitor.clock)
        except Exception as exc:
            diag.emit('WARNING', 'diagnostic_configuration_unavailable', component='manual_monitor',
                      reason_code='MANUAL_MONITOR_UNAVAILABLE', **diag.exception_info(exc))
            value = dict(checked_at=clock(), source_status='UNAVAILABLE', coverage_status='UNAVAILABLE',
                         observation_id=None, heartbeat_at=None, codes=['MANUAL_MONITOR_UNAVAILABLE'])
        value['reserve_policy'] = policy
        return response(ManualDiagnosticView(**value).model_dump(mode='json'))

    @router.post('/control/pause', response_model=ManualControlView)
    def control_pause(body: ManualControlBody, request: Request,
            idempotency_key: Annotated[str, Header(alias='Idempotency-Key', min_length=1, max_length=128)],
            identity=Depends(actor)):
        verified = verify(identity, body, request)
        return response(controls().pause(actor_id=identity['sub'], reason_code=body.reason_code,
            idempotency_key=idempotency_key, expected_epoch=body.expected_epoch, snapshot_digest=body.snapshot_digest,
            authorize=guard(identity, verified)))

    @router.post('/control/resume', response_model=ManualControlView)
    def control_resume(body: ManualControlBody, request: Request,
            idempotency_key: Annotated[str, Header(alias='Idempotency-Key', min_length=1, max_length=128)],
            identity=Depends(actor)):
        verified = verify(identity, body, request)
        return response(controls().resume(monitor=activation_monitor or LazyActivationMonitor(),
            actor_id=identity['sub'], reason_code=body.reason_code, idempotency_key=idempotency_key,
            expected_epoch=body.expected_epoch, snapshot_digest=body.snapshot_digest, authorize=guard(identity, verified)))

    @router.post('/incidents/{id}/ack', response_model=WalletIncidentView)
    def ack(id: str, body: ManualReviewBody, request: Request,
            idempotency_key: Annotated[str, Header(alias='Idempotency-Key', min_length=1, max_length=128)],
            identity=Depends(actor)):
        scope(id)
        verified = verify(identity, body, request)
        return response(incidents.ack(id, identity['sub'], body.reason_code, idempotency_key,
            body.expected_version, authorize=guard(identity, verified)))

    @router.post('/incidents/{id}/review', response_model=WalletIncidentView)
    def recheck(id: str, body: ManualReviewBody, request: Request,
                idempotency_key: Annotated[str, Header(alias='Idempotency-Key', min_length=1, max_length=128)],
                identity=Depends(actor)):
        scope(id)
        verified = verify(identity, body, request)
        arguments = dict(incident_id=id, actor_id=identity['sub'], reason_code=body.reason_code,
            idempotency_key=idempotency_key, expected_version=body.expected_version,
            authorize=guard(identity, verified))
        replay = incidents.replay_manual_review(**arguments)
        if replay is not None:
            return response(replay)
        return response(review(lambda session: incidents.review_manual(session=session, **arguments), incident_id=id))

    @router.post('/incidents/{id}/resolve', response_model=WalletIncidentView)
    def resolve(id: str, body: ManualResolveBody, request: Request,
                idempotency_key: Annotated[str, Header(alias='Idempotency-Key', min_length=1, max_length=128)],
                identity=Depends(actor)):
        scope(id)
        verified = verify(identity, body, request)
        arguments = dict(incident_id=id, actor_id=identity['sub'], reason_code=body.reason_code,
            idempotency_key=idempotency_key, expected_version=body.expected_version, clearance_digest=body.clearance_digest,
            authorize=guard(identity, verified))
        replay = incidents.replay_manual_resolve(**arguments)
        if replay is not None:
            return response(replay)
        return response(review(lambda session: incidents.resolve_manual(session=session, **arguments), incident_id=id))

    return router
