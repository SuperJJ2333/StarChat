"""Session-authenticated manual TRON operations; evidence submission is not payment."""
from typing import Annotated
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Header, Response
from pydantic import BaseModel, ConfigDict, Field, SecretStr

from app.core.errors import AppError
from app.modules.identity.tokens import TokenService
from app.api.admin_wallet_auth import AdminWalletProofBody, selected_password_authorization


class AmountBody(BaseModel):
    model_config = ConfigDict(extra='forbid')
    amount: str = Field(pattern=r'^(0|[1-9][0-9]{0,23})\.[0-9]{6}$')
    expected_binding_version: int = Field(ge=1, strict=True)


class PayoutBody(BaseModel):
    model_config = ConfigDict(extra='forbid')
    quote_id: str = Field(min_length=1, max_length=36)
    mfa_proof: SecretStr | None = Field(default=None, min_length=6, max_length=6, repr=False)


class ClaimBody(AdminWalletProofBody):
    model_config = ConfigDict(extra='forbid')
    expected_digest: str = Field(pattern='^[0-9a-f]{64}$')


class TxidBody(AdminWalletProofBody):
    model_config = ConfigDict(extra='forbid')
    txid: str = Field(pattern='^[0-9a-fA-F]{64}$')


class CorrectionBody(TxidBody):
    reason_code: str = Field(pattern='^[A-Z][A-Z0-9_]{2,79}$')


class PayoutView(BaseModel):
    id: str
    user_id: str
    quote_id: str
    amount: str
    status: str
    digest: str
    candidate_txid: str | None
    settlement_txid: str | None = None
    review_reason: str | None


class InstructionView(BaseModel):
    target_address: str
    official_address: str
    amount: str
    network: str
    contract: str
    digest: str
    warning: str


class ClaimView(PayoutView):
    instructions: InstructionView


class QuoteView(BaseModel):
    id: str
    digest: str
    binding_id: str
    binding_version: int
    target_address: str
    official_address: str
    official_config_version: str
    owner_admin_id: str
    policy_version: str
    approval_policy: str
    finality_policy: str
    network: str
    contract: str
    amount: str
    fee: str
    hold: str
    receive: str
    minimum: str
    max_per: str
    user_24h: str
    global_24h: str
    safety_epoch: int
    created_at: str
    expires_at: str


class IntentView(BaseModel):
    id: str
    binding_id: str
    binding_version: int
    binding_effective_from_block: int
    source_address: str
    official_address: str
    official_config_version: str
    network: str
    rules_snapshot: dict
    status: str
    expected_amount: str
    created_at: str
    expires_at: str
    closed_at: str | None


IdempotencyKey = Annotated[str, Header(alias='Idempotency-Key', min_length=1, max_length=128)]


def create_manual_wallet_router(settings, factory, *, runtime):
    router = APIRouter(prefix='/manual', tags=['manual-wallet'])
    tokens = TokenService(factory, jwt_secret=settings.jwt_secret or 'development-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer=settings.jwt_issuer, require_session_claims=True)

    def actor(response: Response, authorization: Annotated[str | None, Header()] = None):
        response.headers['Cache-Control'] = 'no-store'
        response.headers['X-Content-Type-Options'] = 'nosniff'
        if not authorization or not authorization.startswith('Bearer '):
            raise AppError(code='AUTH_REQUIRED', message='需要登录', status_code=401)
        claims = tokens.decode_access_token(authorization[7:])
        return str(claims['sub']), str(claims['family_id']), claims

    def ready(*, capability=None):
        if runtime is None or capability is not None and not getattr(runtime, capability, runtime.funds_enabled):
            raise AppError(code='WALLET_MANUAL_NOT_READY', message='钱包资金操作暂未开放', status_code=503)
        return runtime

    def call(handler, **kwargs):
        try:
            return handler(**kwargs)
        except ValueError:
            raise AppError(code='WALLET_MANUAL_REJECTED', message='余额、储备或订单状态不满足操作条件', status_code=409) from None

    def recover_closed(capability, component, **kwargs):
        current = ready()
        if getattr(current, capability, current.funds_enabled):
            return None
        return call(getattr(current, component).recover, **kwargs)

    @router.post('/deposit-intents', response_model=IntentView, status_code=201)
    def deposit(body: AmountBody, idempotency_key: IdempotencyKey, identity=Depends(actor)):
        recovered = recover_closed('deposits_enabled', 'intents', user_id=identity[0],
            expected_amount=body.amount, expected_binding_version=body.expected_binding_version, idempotency_key=idempotency_key)
        if recovered is not None:
            return recovered
        return call(ready(capability='deposits_enabled').intents.create, user_id=identity[0], expected_amount=body.amount,
            expected_binding_version=body.expected_binding_version, idempotency_key=idempotency_key)

    @router.get('/deposit-intents/current', response_model=dict[str, IntentView | None])
    def current_deposit(identity=Depends(actor)):
        return {'intent':call(ready().intents.current, user_id=identity[0])}

    @router.get('/deposit-intents/{intent_id}', response_model=IntentView)
    def deposit_status(intent_id: str, identity=Depends(actor)):
        return call(ready().intents.status, user_id=identity[0], intent_id=intent_id)

    @router.post('/payout-quotes', response_model=QuoteView, status_code=201)
    def quote(body: AmountBody, idempotency_key: IdempotencyKey, identity=Depends(actor)):
        recovered = recover_closed('payout_requests_enabled', 'payouts', user_id=identity[0], operation='QUOTE',
            payload=dict(amount=body.amount, binding_version=body.expected_binding_version), idempotency_key=idempotency_key)
        if recovered is not None:
            return recovered
        return call(ready(capability='payout_requests_enabled').payouts.quote, user_id=identity[0], **body.model_dump(), idempotency_key=idempotency_key)

    @router.post('/payouts', response_model=PayoutView, status_code=201)
    def request(body: PayoutBody, idempotency_key: IdempotencyKey, identity=Depends(actor)):
        recovered = recover_closed('payout_requests_enabled', 'payouts', user_id=identity[0], operation='REQUEST',
            payload=dict(quote_id=body.quote_id), idempotency_key=idempotency_key)
        if recovered is not None:
            return recovered
        return call(ready(capability='payout_requests_enabled').payouts.request, user_id=identity[0], session_id=identity[1],
            quote_id=body.quote_id, mfa_proof=body.mfa_proof.get_secret_value() if body.mfa_proof is not None else None, idempotency_key=idempotency_key)

    @router.get('/payouts/{order_id}', response_model=PayoutView)
    def status(order_id: str, identity=Depends(actor)):
        return call(ready().payouts.status, user_id=identity[0], order_id=order_id)

    @router.post('/payouts/{order_id}/cancel', response_model=PayoutView)
    def cancel(order_id: str, idempotency_key: IdempotencyKey, identity=Depends(actor)):
        return call(ready().payouts.cancel, user_id=identity[0], order_id=order_id, idempotency_key=idempotency_key)

    @router.post('/payouts/{order_id}/claim', response_model=ClaimView)
    def claim(order_id: str, body: ClaimBody, idempotency_key: IdempotencyKey, identity=Depends(actor)):
        authorize = selected_password_authorization(settings,factory,lambda:datetime.now(timezone.utc),identity[2],body)
        auth = {'authorize':authorize} if authorize is not None else {'mfa_proof':body.mfa_proof.get_secret_value()}
        return call(ready(capability='payout_execution_enabled').payouts.claim, admin_id=identity[0], session_id=identity[1], order_id=order_id,
            expected_digest=body.expected_digest, idempotency_key=idempotency_key, **auth)

    @router.post('/payouts/{order_id}/txid', response_model=PayoutView)
    def submit(order_id: str, body: TxidBody, idempotency_key: IdempotencyKey, identity=Depends(actor)):
        auth = {}
        if (getattr(settings,'wallet_access_grant_enabled',False)
                or getattr(settings,'wallet_admin_auth_mode','totp') != 'totp' or body.operation_password is not None):
            auth['authorize'] = selected_password_authorization(settings,factory,lambda:datetime.now(timezone.utc),identity[2],body)
        return call(ready().payouts.submit_txid, admin_id=identity[0], order_id=order_id, txid=body.txid,
            idempotency_key=idempotency_key, **auth)

    @router.post('/payouts/{order_id}/correct-candidate', response_model=PayoutView)
    def correct(order_id: str, body: CorrectionBody, idempotency_key: IdempotencyKey, identity=Depends(actor)):
        authorize = selected_password_authorization(settings,factory,lambda:datetime.now(timezone.utc),identity[2],body)
        auth = {'authorize':authorize} if authorize is not None else {'mfa_proof':body.mfa_proof.get_secret_value()}
        return call(ready().payouts.correct_candidate, admin_id=identity[0], session_id=identity[1], order_id=order_id,
            txid=body.txid, reason_code=body.reason_code, idempotency_key=idempotency_key, **auth)

    return router
