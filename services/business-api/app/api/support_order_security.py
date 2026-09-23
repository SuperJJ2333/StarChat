"""Dedicated support-order proof scope, with each staff member's own credential."""
from datetime import datetime, timezone
from typing import Annotated
from fastapi import APIRouter, Depends, Header, Request
from fastapi.responses import JSONResponse
from app.api.admin_wallet_auth import AdminWalletProofBody
from app.api.admin_wallet_security import OperationPasswordBody, WalletSecurityView
from app.api.wallet_access import WalletAccessView
from app.core.errors import AppError
from app.modules.identity.tokens import TokenService
from app.modules.identity.operation_password import AdminWalletOperationPasswordService
from app.modules.identity.wallet_grant import WalletAccessGrantService


def create_support_order_security_router(settings, factory, *, clock=None, mfa_verifier=None):
    router = APIRouter(prefix='/admin/support-orders/security', tags=['support-order-security'])
    clock = clock or (lambda: datetime.now(timezone.utc))
    grants = WalletAccessGrantService(settings, factory, clock, scope='support-orders')
    operations = AdminWalletOperationPasswordService(factory, owner_id=lambda:settings.wallet_manual_owner_admin_id,
        auth_mode=lambda:settings.wallet_admin_auth_mode, clock=clock, scope='support-orders')
    tokens = TokenService(factory, jwt_secret=settings.jwt_secret or 'development-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer=settings.jwt_issuer, require_session_claims=True, now_factory=clock)

    def actor(authorization: Annotated[str | None, Header()] = None):
        if not authorization or not authorization.startswith('Bearer '):
            raise AppError(code='AUTH_REQUIRED', message='需要管理会话', status_code=401)
        return tokens.decode_access_token(authorization[7:])

    def response(value):
        return JSONResponse(value, headers={'Cache-Control':'no-store', 'X-Content-Type-Options':'nosniff'})

    @router.get('', response_model=WalletAccessView)
    def status(claims=Depends(actor)):
        return response(grants.status(claims=claims))

    @router.post('/verify', response_model=WalletAccessView)
    def verify(body: AdminWalletProofBody, request: Request, claims=Depends(actor)):
        verifier = mfa_verifier
        if settings.wallet_admin_auth_mode == 'totp' and verifier is None:
            from app.modules.identity.totp import FernetSecretProtector, TotpService
            from app.modules.wallet.binding_adapters import WalletTotpVerifier
            key, limiter = settings.wallet_totp_encryption_key, getattr(request.app.state, 'rate_limiter', None)
            if key is None or limiter is None:
                raise AppError(code='WALLET_MFA_NOT_CONFIGURED', message='动态验证码服务尚未配置', status_code=503)
            verifier = WalletTotpVerifier(TotpService(factory, protector=FernetSecretProtector(
                key.get_secret_value().encode('ascii')), now_factory=clock), limiter, clock=clock)
        try:
            result = grants.verify(claims=claims,
                operation_password=body.operation_password.get_secret_value() if body.operation_password else None,
                mfa_proof=body.mfa_proof.get_secret_value() if body.mfa_proof else None, mfa_verifier=verifier)
        except AppError as exc:
            if exc.code in {'OPERATION_PASSWORD_INVALID','OPERATION_PASSWORD_NOT_CONFIGURED','TOTP_INVALID','TOTP_REPLAYED'}:
                raise AppError(code=exc.code,message=exc.message,status_code=403) from None
            raise
        return response(result)

    @router.post('/revoke', response_model=WalletAccessView)
    def revoke(claims=Depends(actor)):
        return response(grants.revoke(claims=claims))

    @router.get('/operation-password', response_model=WalletSecurityView)
    def operation_status(claims=Depends(actor)):
        return response(operations.status(claims=claims, grant_verification=True))

    @router.put('/operation-password', response_model=WalletSecurityView)
    def set_password(body: OperationPasswordBody,
            idempotency_key: Annotated[str, Header(alias='Idempotency-Key',min_length=1,max_length=128)],claims=Depends(actor)):
        if settings.wallet_admin_auth_mode != 'operation_password':
            raise AppError(code='ADMIN_WALLET_AUTH_MODE_MISMATCH',message='当前使用动态验证码验证',status_code=403)
        return response(operations.set_password(claims=claims,idempotency_key=idempotency_key,
            login_password=body.login_password.get_secret_value(),new_operation_password=body.new_operation_password.get_secret_value(),
            current_operation_password=body.current_operation_password.get_secret_value() if body.current_operation_password else None))
    return router
