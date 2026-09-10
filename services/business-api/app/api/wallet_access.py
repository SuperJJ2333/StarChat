"""Authenticated access status and explicit verification; no client proof cache."""
from datetime import datetime, timezone
from typing import Annotated
from fastapi import APIRouter, Depends, Header, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from app.api.admin_wallet_auth import AdminWalletProofBody, wallet_grant_service
from app.core.errors import AppError
from app.modules.identity.tokens import TokenService


class WalletAccessView(BaseModel):
    enabled: bool
    verified: bool
    auth_mode: str
    configured: bool
    grant_id: str | None
    verified_at: str | None
    expires_at: str | None
    server_time: str


def create_wallet_access_router(settings, factory, *, clock=None, mfa_verifier=None):
    router = APIRouter(prefix='/wallet/manual/access', tags=['wallet-access'])
    clock = clock or (lambda:datetime.now(timezone.utc))
    service = wallet_grant_service(settings, factory, clock)
    tokens = TokenService(factory, jwt_secret=settings.jwt_secret or 'development-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer=settings.jwt_issuer, require_session_claims=True, now_factory=clock)

    def actor(authorization: Annotated[str | None, Header()] = None):
        if not authorization or not authorization.startswith('Bearer '):
            raise AppError(code='AUTH_REQUIRED', message='AUTH_REQUIRED', status_code=401)
        return tokens.decode_access_token(authorization[7:])

    def response(value):
        return JSONResponse(value, headers={'Cache-Control':'no-store', 'X-Content-Type-Options':'nosniff'})

    @router.get('', response_model=WalletAccessView)
    def status(claims=Depends(actor)):
        if not getattr(settings, 'wallet_access_grant_enabled', False):
            if claims.get('session_scope') != 'admin':
                raise AppError(code='PERMISSION_DENIED', message='PERMISSION_DENIED', status_code=403)
            return response(dict(enabled=False, verified=False, auth_mode=settings.wallet_admin_auth_mode,
                configured=False, grant_id=None, verified_at=None, expires_at=None, server_time=clock().isoformat()))
        return response(service.status(claims=claims))

    @router.post('/verify', response_model=WalletAccessView)
    def verify(body: AdminWalletProofBody, request: Request, claims=Depends(actor)):
        verifier = mfa_verifier
        if settings.wallet_admin_auth_mode == 'totp' and verifier is None:
            from app.modules.identity.totp import FernetSecretProtector, TotpService
            from app.modules.wallet.binding_adapters import WalletTotpVerifier
            key = settings.wallet_totp_encryption_key
            limiter = getattr(request.app.state, 'rate_limiter', None)
            if key is None or limiter is None:
                raise AppError(code='WALLET_MFA_NOT_CONFIGURED', message='WALLET_MFA_NOT_CONFIGURED', status_code=503)
            verifier = WalletTotpVerifier(TotpService(factory, protector=FernetSecretProtector(
                key.get_secret_value().encode('ascii')), now_factory=clock), limiter, clock=clock)
        try:
            result = service.verify(claims=claims,
                operation_password=body.operation_password.get_secret_value() if body.operation_password else None,
                mfa_proof=body.mfa_proof.get_secret_value() if body.mfa_proof else None, mfa_verifier=verifier)
        except AppError as exc:
            if exc.code in {'OPERATION_PASSWORD_INVALID', 'OPERATION_PASSWORD_NOT_CONFIGURED', 'TOTP_INVALID', 'TOTP_REPLAYED'}:
                raise AppError(code=exc.code, message=exc.message, status_code=403) from None
            raise
        return response(result)

    @router.post('/revoke', response_model=WalletAccessView)
    def revoke(claims=Depends(actor)):
        return response(service.revoke(claims=claims))

    return router
