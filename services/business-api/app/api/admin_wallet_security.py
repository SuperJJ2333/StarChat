"""Administrator operation-password setup; user MFA remains separate."""
from datetime import datetime, timezone
from typing import Annotated
from fastapi import APIRouter, Depends, Header
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, SecretStr
from app.core.errors import AppError
from app.modules.identity.tokens import TokenService
from app.modules.identity.operation_password import AdminWalletOperationPasswordService


class OperationPasswordBody(BaseModel):
    model_config=ConfigDict(extra='forbid')
    login_password: SecretStr=Field(min_length=1,max_length=256,repr=False)
    new_operation_password: SecretStr=Field(min_length=12,max_length=128,repr=False)
    current_operation_password: SecretStr | None=Field(default=None,min_length=12,max_length=128,repr=False)


class WalletSecurityView(BaseModel):
    auth_mode: str
    configured: bool
    version: int


def create_admin_wallet_security_router(settings,factory,*,clock=None):
    router=APIRouter(prefix='/wallet/security',tags=['admin-wallet-security'])
    clock=clock or (lambda:datetime.now(timezone.utc))
    tokens=TokenService(factory,jwt_secret=settings.jwt_secret or 'development-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer=settings.jwt_issuer,require_session_claims=True,now_factory=clock)
    service=AdminWalletOperationPasswordService(factory,owner_id=lambda:settings.wallet_manual_owner_admin_id,
        auth_mode=lambda:getattr(settings,'wallet_admin_auth_mode','totp'),clock=clock)
    def actor(authorization: Annotated[str | None,Header()]=None):
        if not authorization or not authorization.startswith('Bearer '):
            raise AppError(code='AUTH_REQUIRED',message='AUTH_REQUIRED',status_code=401)
        return tokens.require_recent_login(authorization[7:])
    def response(value):
        return JSONResponse(value,headers={'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'})
    def status_actor(authorization: Annotated[str | None,Header()]=None):
        if not getattr(settings, 'wallet_access_grant_enabled', False):
            return actor(authorization)
        if not authorization or not authorization.startswith('Bearer '):
            raise AppError(code='AUTH_REQUIRED',message='AUTH_REQUIRED',status_code=401)
        claims = tokens.decode_access_token(authorization[7:])
        return claims
    @router.get('',response_model=WalletSecurityView)
    def status(claims=Depends(status_actor)):
        if getattr(settings, 'wallet_access_grant_enabled', False):
            return response(service.status(claims=claims, grant_verification=True))
        return response(service.status(claims=claims))
    @router.post('/operation-password',response_model=WalletSecurityView)
    def set_password(body:OperationPasswordBody,
            idempotency_key:Annotated[str,Header(alias='Idempotency-Key',min_length=1,max_length=128)],claims=Depends(actor)):
        return response(service.set_password(claims=claims,idempotency_key=idempotency_key,
            login_password=body.login_password.get_secret_value(),new_operation_password=body.new_operation_password.get_secret_value(),
            current_operation_password=body.current_operation_password.get_secret_value() if body.current_operation_password else None))
    return router
