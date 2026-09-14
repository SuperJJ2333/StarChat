"""Wallet-grant protected manual review commands, mounted within /admin."""
from datetime import datetime, timezone
from typing import Annotated, Literal
from fastapi import APIRouter, Depends, Header, Query
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, field_validator
from app.api.admin_wallet_auth import wallet_grant_service
from app.modules.identity.tokens import TokenService
from app.modules.wallet.repairs import DepositRepairService, fail
from app.modules.wallet.repair_payouts import PayoutReconciliationService
from app.modules.wallet.manual_deposit_cases import ManualDepositCaseService


class RepairBody(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)


class DepositRepairPreviewBody(RepairBody):
    receipt_id: str = Field(min_length=1, max_length=36)
    intent_id: str = Field(min_length=1, max_length=36)
    reason_code: Literal['CLOCK_ORDERING_REVIEW', 'EXPIRED_INTENT_REVIEW', 'ATTRIBUTION_CORRECTION', 'PAYMENT_BEFORE_ORDER', 'OTHER']
    reason_detail: str = Field(min_length=1, max_length=500)
    payment_attestation: bool = False


class PayoutReconciliationPreviewBody(RepairBody):
    order_id: str = Field(min_length=1, max_length=36)
    txid: str = Field(pattern='^[a-f0-9]{64}$')
    log_index: int = Field(ge=0)
    reason_detail: str = Field(min_length=1, max_length=500)


class RepairExecuteBody(RepairBody):
    preview_id: str = Field(min_length=1, max_length=36)
    digest: str = Field(pattern='^[a-f0-9]{64}$')
    expected_version: int = Field(ge=1)
    operation_id: str = Field(pattern='^[A-Za-z0-9-]{1,36}$')
    confirmed: Literal[True]

    @field_validator('confirmed', mode='before')
    @classmethod
    def explicit_confirmation(cls, value):
        if value is not True:
            raise ValueError('explicit boolean confirmation required')
        return value


class ManualDepositCaseBody(RepairBody):
    receipt_id: str = Field(min_length=1, max_length=36)
    user_id: str = Field(min_length=1, max_length=36)
    reason_detail: str = Field(min_length=1, max_length=500)
    ownership_attestation: Literal[True]

    @field_validator('ownership_attestation', mode='before')
    @classmethod
    def explicit_ownership_attestation(cls, value):
        if value is not True:
            raise ValueError('explicit boolean ownership attestation required')
        return value


class ManualDepositDecisionBody(RepairBody):
    decision: Literal['APPROVED', 'REJECTED']
    reason_detail: str = Field(min_length=1, max_length=500)
    confirmed: Literal[True]

    @field_validator('confirmed', mode='before')
    @classmethod
    def explicit_decision_confirmation(cls, value):
        if value is not True:
            raise ValueError('explicit boolean confirmation required')
        return value


def create_admin_wallet_repairs_router(settings, factory, *, runtime, clock_trusted=lambda: False):
    router = APIRouter(prefix='/wallet/manual', tags=['admin-wallet-repairs'])
    clock = lambda: datetime.now(timezone.utc)
    tokens = TokenService(factory, jwt_secret=settings.jwt_secret or 'development-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer=settings.jwt_issuer, require_session_claims=True)
    grants = wallet_grant_service(settings, factory, clock)
    deposits = (DepositRepairService(factory, receipts=runtime.receipts,
        owner_admin_id=settings.wallet_manual_owner_admin_id, clock_trusted=clock_trusted) if runtime else None)
    payouts = PayoutReconciliationService(factory, payouts=runtime.payouts, deposits=deposits) if runtime else None
    cases = (ManualDepositCaseService(factory, receipts=runtime.receipts,
        owner_admin_id=settings.wallet_manual_owner_admin_id, clock_trusted=clock_trusted) if runtime else None)

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

    def response(payload):
        return JSONResponse(payload, headers={'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff'})

    def context(claims):
        return dict(actor_id=claims['sub'], authorize=grants.authorization(claims=claims))

    def write_gate():
        if not getattr(settings, 'wallet_manual_repairs_enabled', False):
            fail('MANUAL_REPAIRS_DISABLED', 503)

    def write_context(claims):
        def authorize(session):
            fresh = grants.authorization(claims=claims)(session)
            def commit_check():
                write_gate()
                fresh()
            return commit_check
        return dict(actor_id=claims['sub'], authorize=authorize)

    @router.get('/deposit-repairs/candidates')
    def candidates(claims=Depends(actor), txid: str = Query(pattern='^[a-f0-9]{64}$'),
                   log_index: int = Query(ge=0), query: str | None = Query(None, max_length=128)):
        return response(deposits.candidates(**context(claims), txid=txid, log_index=log_index, query=query))

    @router.post('/deposit-repairs/preview')
    def deposit_preview(body: DepositRepairPreviewBody, claims=Depends(actor)):
        return response(deposits.preview(**context(claims), **body.model_dump()))

    @router.post('/deposit-repairs')
    def deposit_execute(body: RepairExecuteBody, claims=Depends(actor),
                        idempotency_key: str = Header(min_length=1, max_length=128)):
        write_gate()
        return response(deposits.execute(**write_context(claims), **body.model_dump(exclude={'confirmed'}), idempotency_key=idempotency_key))

    @router.get('/deposit-repairs/{operation_id}')
    def deposit_status(operation_id: str, claims=Depends(actor)):
        return response(deposits.status(**context(claims), operation_id=operation_id))

    @router.get('/manual-deposit-cases/context')
    def manual_case_context(claims=Depends(actor), txid: str = Query(pattern='^[a-f0-9]{64}$'), log_index: int = Query(ge=0)):
        return response(cases.context(**context(claims), txid=txid, log_index=log_index))

    @router.post('/manual-deposit-cases')
    def manual_case_create(body: ManualDepositCaseBody, claims=Depends(actor), idempotency_key: str = Header(min_length=1, max_length=128)):
        write_gate(); return response(cases.create(**write_context(claims), **body.model_dump(), idempotency_key=idempotency_key))

    @router.get('/manual-deposit-cases/operations/{operation_id}')
    def manual_case_operation(operation_id: str, claims=Depends(actor)):
        return response(cases.status(**context(claims), operation_id=operation_id))

    @router.post('/manual-deposit-cases/{case_id}/decision')
    def manual_case_decision(case_id: str, body: ManualDepositDecisionBody, claims=Depends(actor), idempotency_key: str = Header(min_length=1, max_length=128)):
        write_gate(); return response(cases.decide(**write_context(claims), case_id=case_id, **body.model_dump(), idempotency_key=idempotency_key))

    @router.post('/manual-deposit-cases/{case_id}/preview')
    def manual_case_preview(case_id: str, claims=Depends(actor)):
        return response(cases.preview(**context(claims), case_id=case_id))

    @router.post('/manual-deposit-cases/{case_id}/execute')
    def manual_case_execute(case_id: str, body: RepairExecuteBody, claims=Depends(actor), idempotency_key: str = Header(min_length=1, max_length=128)):
        write_gate(); return response(cases.execute(**write_context(claims), case_id=case_id, **body.model_dump(exclude={'confirmed'}), idempotency_key=idempotency_key))

    @router.get('/manual-deposit-cases/{case_id}')
    def manual_case_get(case_id: str, claims=Depends(actor)):
        return response(cases.get(**context(claims), case_id=case_id))

    @router.post('/payout-reconciliations/preview')
    def payout_preview(body: PayoutReconciliationPreviewBody, claims=Depends(actor)):
        return response(payouts.preview(**context(claims), **body.model_dump()))

    @router.post('/payout-reconciliations')
    def payout_execute(body: RepairExecuteBody, claims=Depends(actor),
                       idempotency_key: str = Header(min_length=1, max_length=128)):
        write_gate()
        return response(payouts.execute(**write_context(claims), **body.model_dump(exclude={'confirmed'}), idempotency_key=idempotency_key))

    @router.get('/payout-reconciliations/{operation_id}')
    def payout_status(operation_id: str, claims=Depends(actor)):
        return response(payouts.status(**context(claims), operation_id=operation_id))

    return router
