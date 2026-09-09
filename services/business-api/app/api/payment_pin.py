"""Payment PIN enrollment and intent authorization; secrets never enter URLs."""
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Header, Request, Response
from pydantic import BaseModel, ConfigDict, Field, SecretStr

from app.core.errors import AppError
from app.modules.identity.payment_pin import PaymentPinService
from app.modules.identity.tokens import TokenService


class SetupPaymentPinRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    pin: SecretStr = Field(min_length=6, max_length=6, repr=False)
    login_password: SecretStr = Field(min_length=1, max_length=256, repr=False)


class AuthorizePaymentPinRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    pin: SecretStr = Field(min_length=6, max_length=6, repr=False)
    action: Literal['chat_transfer.create', 'red_packet.create']
    payload: dict
    idempotency_key: str = Field(min_length=1, max_length=128)


class PaymentPinStatus(BaseModel):
    configured: bool
    locked_until: str | None = None


class PaymentPinAuthorizationView(BaseModel):
    authorization: str = Field(repr=False)
    expires_in: int


def create_payment_pin_router(settings, factory, rate_limiter):
    router = APIRouter(prefix='/payment-pin', tags=['payment-pin'])
    service = PaymentPinService(factory, require_all=settings.payment_pin_require_all, rate_limiter=rate_limiter)
    tokens = TokenService(factory, jwt_secret=settings.jwt_secret or 'development-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer=settings.jwt_issuer, require_session_claims=True)

    def actor(response: Response, authorization: Annotated[str | None, Header()] = None):
        response.headers['Cache-Control'] = 'no-store'
        if not authorization or not authorization.startswith('Bearer '):
            raise AppError(code='AUTH_REQUIRED', message='需要登录', status_code=401)
        return tokens.decode_access_token(authorization[7:])

    @router.get('/status', response_model=PaymentPinStatus)
    def status(claims=Depends(actor)):
        return service.status(claims=claims)

    @router.post('/setup', response_model=PaymentPinStatus)
    def setup(body: SetupPaymentPinRequest, request: Request,
              idempotency_key: Annotated[str, Header(alias='Idempotency-Key', min_length=1, max_length=128)], claims=Depends(actor)):
        return service.setup(claims=claims, pin=body.pin.get_secret_value(), login_password=body.login_password.get_secret_value(),
            idempotency_key=idempotency_key, ip=request.client.host if request.client else '')

    @router.post('/authorize', response_model=PaymentPinAuthorizationView)
    def authorize(body: AuthorizePaymentPinRequest, request: Request, claims=Depends(actor)):
        return service.authorize(claims=claims, pin=body.pin.get_secret_value(), action=body.action, payload=body.payload,
            idempotency_key=body.idempotency_key, ip=request.client.host if request.client else '')

    return router
