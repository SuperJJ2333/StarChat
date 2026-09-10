"""Sole-owner exact-manifest legacy handover; client assertions never substitute chain proof."""
from datetime import datetime, timezone
from typing import Annotated, Literal
from fastapi import APIRouter, Depends, Header, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, SecretStr
from app.core.errors import AppError
from app.api.admin_wallet_auth import AdminWalletProofBody, selected_password_authorization, wallet_grant_service
from app.modules.identity.tokens import TokenService
from app.modules.identity.wallet_access import require_wallet_actor, require_wallet_session
from app.modules.ledger.reserve import lock_budget
from app.modules.wallet.handover import LegacyWalletHandover
from app.modules.wallet.models import WalletControl


class HandoverPrepareBody(AdminWalletProofBody):
    model_config = ConfigDict(extra='forbid')
    reason_code: str = Field(pattern=r'^[A-Z][A-Z0-9_]{2,99}$')


class HandoverManifestBody(HandoverPrepareBody):
    manifest_digest: str = Field(pattern=r'^[a-f0-9]{64}$')


class HandoverConfirmBody(HandoverManifestBody):
    no_unregistered_payments: Literal[True]
    notice_received: Literal[True]


class HandoverView(BaseModel):
    id: str
    manifest_digest: str
    expires_at: str
    status: Literal['PREPARED','NOTICE_PENDING','NOTICE_DELIVERED','EXPIRED','INVALID','HANDOVER_COMPLETE_FUNDS_PAUSED']
    incident_count: int
    alert_count: int
    notice_id: str | None
    disposition_kind: str | None
    withdrawals_paused: bool
    invalid_reason: str | None = None
    incidents: list[dict]
    source_configuration_version: str
    deployment_record_sha256: str


def create_manual_wallet_handover_router(settings, factory, *, monitor_factory=None, mfa_verifier=None, clock=None):
    router = APIRouter(prefix='/wallet/manual/handover', tags=['manual-wallet-handover'])
    clock = clock or (lambda: datetime.now(timezone.utc))
    tokens = TokenService(factory, jwt_secret=settings.jwt_secret or 'development-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer=settings.jwt_issuer, require_session_claims=True, now_factory=clock)

    def fail(code, status):
        raise AppError(code=code, message=code, status_code=status)

    def actor(authorization: Annotated[str | None, Header()] = None):
        if not authorization or not authorization.startswith('Bearer '):
            fail('AUTH_REQUIRED', 401)
        if getattr(settings, 'wallet_access_grant_enabled', False):
            claims = tokens.decode_access_token(authorization[7:])
            wallet_grant_service(settings, factory, clock).require(claims=claims)
        else:
            claims = tokens.require_recent_login(authorization[7:])
        if settings.wallet_real_mode != 'manual_tron' or claims['sub'] != settings.wallet_manual_owner_admin_id:
            fail('PERMISSION_DENIED', 403)
        with factory.begin() as session:
            require_wallet_actor(session, user_id=claims['sub'], clock=clock, administrator=True)
        return claims

    def proof(identity, body, request):
        password_authorize = selected_password_authorization(settings, factory, clock, identity, body)
        if password_authorize is not None:
            return password_authorize
        verifier = mfa_verifier
        if verifier is None:
            from app.modules.identity.totp import FernetSecretProtector, TotpService
            from app.modules.wallet.binding_adapters import WalletTotpVerifier
            key = settings.wallet_totp_encryption_key
            limiter = getattr(request.app.state, 'rate_limiter', None)
            if key is None or limiter is None:
                fail('WALLET_MFA_NOT_CONFIGURED', 503)
            verifier = WalletTotpVerifier(TotpService(factory, protector=FernetSecretProtector(
                key.get_secret_value().encode('ascii')), now_factory=clock), limiter, clock=clock)
        if verifier(user_id=identity['sub'], session_id=identity['family_id'],
                proof=body.mfa_proof.get_secret_value(), now=clock()) is not True:
            fail('TOTP_REQUIRED', 403)
        verified_at = clock()
        def authorize(session):
            lock_budget(session)
            session.get(WalletControl, 'global', with_for_update=True)
            if settings.wallet_real_mode != 'manual_tron' or identity['sub'] != settings.wallet_manual_owner_admin_id:
                fail('PERMISSION_DENIED', 403)
            require_wallet_actor(session, user_id=identity['sub'], clock=clock, administrator=True)
            session_fresh = require_wallet_session(session, claims=identity, clock=clock, verified_at=verified_at)
            def fresh():
                if getattr(settings,'wallet_admin_auth_mode','totp') != 'totp':
                    fail('ADMIN_WALLET_AUTH_MODE_MISMATCH',403)
                session_fresh()
            fresh()
            return fresh
        return authorize

    def service():
        if monitor_factory is not None:
            monitor = monitor_factory()
        else:
            from app.integrations.tron.funding_source import SQLiteFundingSource
            from app.modules.wallet.funding import OfficialFundingConfig
            from app.modules.wallet.manual_reserve_monitor import ManualReserveMonitor
            from app.modules.wallet.monitoring import WalletMonitoringService
            official = OfficialFundingConfig(settings.wallet_official_address.get_secret_value(), settings.wallet_official_config_version)
            source = SQLiteFundingSource(settings.tron_observer_database_path, official_address=official.address,
                clock=clock, solid_head_max_age_seconds=180)
            monitor = ManualReserveMonitor(factory, source=source, official_config=official,
                activation_baseline_time=settings.wallet_funding_baseline_at,
                activation_baseline_height=settings.wallet_funding_baseline_height, clock=clock,
                external_delivery_configured=WalletMonitoringService(factory).status()['external_delivery_configured'])
        monitor.reserve_policy = getattr(settings, 'wallet_reserve_policy', 'full_backing')
        return LegacyWalletHandover(factory, monitor=monitor, deployment_record_path=settings.wallet_handover_deployment_record_path,
            clock=clock, preparation_mode=lambda: settings.wallet_handover_preparation_mode,
            funds_enabled=lambda: any(value is True for value in (settings.wallet_real_funds_enabled,
                getattr(settings, 'wallet_deposits_enabled', False), getattr(settings, 'wallet_payout_requests_enabled', False),
                getattr(settings, 'wallet_payout_execution_enabled', False), getattr(settings, 'wallet_conversions_enabled', False))))

    def response(value):
        return JSONResponse(value, headers={'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'})

    @router.post('/prepare', response_model=HandoverView)
    def prepare(body: HandoverPrepareBody, request: Request,
            idempotency_key: Annotated[str, Header(alias='Idempotency-Key', min_length=1, max_length=128)], identity=Depends(actor)):
        authorize = proof(identity, body, request)
        return response(service().prepare(actor_id=identity['sub'], reason_code=body.reason_code,
            idempotency_key=idempotency_key, authorize=authorize))

    @router.get('/{id}', response_model=HandoverView)
    def status(id: str, identity=Depends(actor)):
        return response(service().status(id, actor_id=identity['sub']))

    @router.post('/{id}/notify', response_model=HandoverView)
    def notify(id: str, body: HandoverManifestBody, request: Request,
            idempotency_key: Annotated[str, Header(alias='Idempotency-Key', min_length=1, max_length=128)], identity=Depends(actor)):
        authorize = proof(identity, body, request)
        return response(service().notify(preparation_id=id, manifest_digest=body.manifest_digest,
            actor_id=identity['sub'], reason_code=body.reason_code, idempotency_key=idempotency_key, authorize=authorize))

    @router.post('/{id}/confirm', response_model=HandoverView)
    def confirm(id: str, body: HandoverConfirmBody, request: Request,
            idempotency_key: Annotated[str, Header(alias='Idempotency-Key', min_length=1, max_length=128)], identity=Depends(actor)):
        authorize = proof(identity, body, request)
        return response(service().confirm(preparation_id=id, manifest_digest=body.manifest_digest,
            no_unregistered_payments=body.no_unregistered_payments, notice_received=body.notice_received,
            actor_id=identity['sub'], reason_code=body.reason_code, idempotency_key=idempotency_key, authorize=authorize))

    return router
