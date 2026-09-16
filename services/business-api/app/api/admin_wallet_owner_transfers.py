"""Owner-transfer declaration endpoints for the official wallet holder (ADR-0071)."""
from datetime import datetime, timezone
from typing import Annotated
from fastapi import APIRouter, Depends, Header, Path
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field
from app.api.admin_wallet_auth import wallet_grant_service
from app.modules.identity.tokens import TokenService
from app.modules.wallet.owner_transfers import OwnerTransferService
from app.modules.wallet.repairs import fail

REASON_PATTERN = r'^[A-Z][A-Z0-9_]{2,99}$'


class OwnerTransferBody(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    txid: str = Field(pattern=r'^[a-f0-9]{64}$')
    log_index: int = Field(ge=0)
    reason_code: str = Field(pattern=REASON_PATTERN)
    reason_detail: str = Field(min_length=1, max_length=500)
    ownership_attested: bool


def create_admin_owner_transfer_router(settings, factory, *, runtime, clock_trusted=lambda: False):
    router = APIRouter(prefix='/wallet/manual/owner-transfers', tags=['admin-wallet-owner-transfers'])
    tokens = TokenService(factory, jwt_secret=settings.jwt_secret or 'development-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer=settings.jwt_issuer, require_session_claims=True)
    grants = wallet_grant_service(settings, factory, lambda: datetime.now(timezone.utc))
    service = (OwnerTransferService(factory, ledger=runtime.receipts.wallet_ledger,
        finality_adapter=runtime.receipts.adapter, official_config=runtime.receipts.official_config,
        owner_admin_id=settings.wallet_manual_owner_admin_id, clock_trusted=clock_trusted,
        clock=runtime.receipts.clock) if runtime else None)

    def response(payload):
        return JSONResponse(payload, headers={'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff'})

    def actor(authorization: Annotated[str | None, Header()] = None):
        if not authorization or not authorization.startswith('Bearer '):
            fail('AUTH_REQUIRED', 401)
        claims = tokens.decode_access_token(authorization[7:])
        if (runtime is None or settings.wallet_real_mode != 'manual_tron'
                or claims['sub'] != settings.wallet_manual_owner_admin_id):
            fail('PERMISSION_DENIED', 403)
        if not getattr(settings, 'wallet_access_grant_enabled', False):
            fail('WALLET_VERIFICATION_REQUIRED', 403)
        grants.require(claims=claims)
        return claims

    def write_gate():
        if not getattr(settings, 'wallet_owner_transfers_enabled', False):
            fail('OWNER_TRANSFERS_DISABLED', 503)

    def write_context(claims):
        def authorize(session):
            fresh = grants.authorization(claims=claims)(session)
            def commit_check():
                write_gate()
                fresh()
            return commit_check
        return dict(actor_id=claims['sub'], authorize=authorize)

    @router.post('/preview')
    def preview(body: OwnerTransferBody, claims=Depends(actor)):
        return response(service.preview(**write_context(claims), **body.model_dump()))

    @router.post('')
    def execute(body: OwnerTransferBody, claims=Depends(actor),
                idempotency_key: Annotated[str, Header(alias='Idempotency-Key', min_length=1, max_length=128)] = None):
        if not idempotency_key:
            fail('REPAIR_IDEMPOTENCY_INVALID', 422)
        write_gate()
        return response(service.execute(**write_context(claims), **body.model_dump(),
            idempotency_key=idempotency_key))

    @router.get('/{txid}')
    def status(txid: str = Path(pattern=r'^[a-f0-9]{64}$'), claims=Depends(actor)):
        return response(service.status(**write_context(claims), txid=txid))

    return router
