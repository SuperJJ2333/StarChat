"""Authenticated MFA provisioning; no fallback encryption key or reset bypass."""
from datetime import datetime, timezone
from typing import Annotated
from urllib.parse import quote, urlencode

from fastapi import APIRouter, Depends, Header, Response
from pydantic import BaseModel, ConfigDict, Field, SecretStr

from app.core.errors import AppError
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.tokens import TokenService
from app.modules.identity.totp import FernetSecretProtector
from app.modules.identity.wallet_mfa import WalletMfaService


class EnrollmentBody(BaseModel):
    model_config = ConfigDict(extra='forbid')
    password: SecretStr = Field(min_length=1, max_length=256, repr=False)


class EnableBody(BaseModel):
    model_config = ConfigDict(extra='forbid')
    credential_id: str = Field(min_length=1, max_length=36)
    code: SecretStr = Field(min_length=6, max_length=6, repr=False)
    setup_proof: SecretStr | None = Field(default=None, min_length=1, max_length=4096, repr=False)


class AbortBody(EnrollmentBody):
    credential_id: str = Field(min_length=1, max_length=36)


class EnrollmentView(BaseModel):
    credential_id: str
    secret: str = Field(repr=False)
    provisioning_uri: str = Field(repr=False)
    setup_proof: str = Field(repr=False)


class SetupProofView(BaseModel):
    setup_proof: str = Field(repr=False)
    expires_in: int


class MfaStatus(BaseModel):
    configured: bool
    enabled: bool
    enrolled_at: str | None
    pending_credential_id: str | None = None


class EnabledView(BaseModel):
    enabled: bool


def create_wallet_mfa_router(settings, factory, rate_limiter):
    router = APIRouter(prefix='/security/mfa', tags=['wallet-mfa'])
    tokens = TokenService(factory, jwt_secret=settings.jwt_secret or 'development-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer=settings.jwt_issuer, require_session_claims=True)
    key = settings.wallet_totp_encryption_key
    protector = None
    if key is not None:
        protector = FernetSecretProtector(key.get_secret_value().encode('ascii'))
    service = WalletMfaService(factory, protector=protector, password_hasher=PasswordHasher(),
        rate_limiter=rate_limiter, clock=lambda: datetime.now(timezone.utc))

    def actor(response: Response, authorization: Annotated[str | None, Header()] = None):
        response.headers['Cache-Control'] = 'no-store'
        response.headers['X-Content-Type-Options'] = 'nosniff'
        if not authorization or not authorization.startswith('Bearer '):
            raise AppError(code='AUTH_REQUIRED', message='需要登录', status_code=401)
        claims = tokens.decode_access_token(authorization[7:])
        return str(claims['sub']), str(claims['family_id'])

    @router.get('', response_model=MfaStatus)
    def status(identity=Depends(actor)):
        return service.status(user_id=identity[0])

    @router.post('/enroll', response_model=EnrollmentView, status_code=201)
    def enroll(body: EnrollmentBody, identity=Depends(actor)):
        result = service.begin(user_id=identity[0], session_id=identity[1], password=body.password.get_secret_value())
        label = quote(settings.totp_issuer + ':' + identity[0], safe='')
        result['provisioning_uri'] = 'otpauth://totp/' + label + '?' + urlencode({
            'secret': result['secret'], 'issuer': settings.totp_issuer, 'algorithm':'SHA1', 'digits':6, 'period':30})
        return result

    @router.post('/enable', response_model=EnabledView)
    def enable(body: EnableBody, identity=Depends(actor)):
        return service.enable(user_id=identity[0], session_id=identity[1], credential_id=body.credential_id,
            code=body.code.get_secret_value(),
            setup_proof=body.setup_proof.get_secret_value() if body.setup_proof is not None else None)

    @router.post('/reauthenticate', response_model=SetupProofView)
    def reauthenticate(body: AbortBody, identity=Depends(actor)):
        return service.reauthenticate(user_id=identity[0], session_id=identity[1], credential_id=body.credential_id,
            password=body.password.get_secret_value())

    @router.post('/abort-pending', response_model=EnabledView)
    def abort(body: AbortBody, identity=Depends(actor)):
        return service.abort_pending(user_id=identity[0], session_id=identity[1], credential_id=body.credential_id,
            password=body.password.get_secret_value())

    return router
