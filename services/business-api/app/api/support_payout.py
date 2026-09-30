"""Management-session support payout queue; all financial proof is scope-bound."""
from typing import Annotated, Literal
from fastapi import APIRouter, Depends, Header, Query, Response
from pydantic import BaseModel, ConfigDict, Field
from app.api.admin_wallet_auth import AdminWalletProofBody
from app.api.admin_wallet_auth import wallet_grant_service
from app.core.errors import AppError
from app.modules.identity.support_order_auth import fresh_owner_proof_authorization
from app.modules.identity.tokens import TokenService
from app.modules.wallet.support_payout import SupportPayoutService


class EmptyBody(BaseModel):
    model_config=ConfigDict(extra='forbid')


class LeaseBody(EmptyBody):
    claim_token: str=Field(min_length=32,max_length=64,repr=False)


class FinancialLeaseBody(LeaseBody):
    proof: AdminWalletProofBody|None=Field(default=None,repr=False)
    expected_version: int=Field(ge=1,strict=True)
    expected_claim_version: int=Field(ge=0,strict=True)


class BeginBody(FinancialLeaseBody):
    expected_digest: str=Field(pattern=r'^[0-9a-f]{64}$')
    expected_preparation_version: int|None=Field(default=None,ge=0,strict=True)


class RateBody(FinancialLeaseBody):
    new_rate: str=Field(pattern=r'^(0|[1-9][0-9]{0,3})(\.[0-9]{1,6})?$')
    reason_code: str=Field(min_length=3,max_length=100)
    expected_preparation_version: int|None=Field(default=None,ge=0,strict=True)


class RejectBody(LeaseBody):
    reason_code: Literal['PAYOUT_ADDRESS_INVALID', 'PAYOUT_DETAILS_MISMATCH',
        'PAYOUT_POLICY_INELIGIBLE']
    proof: AdminWalletProofBody|None=Field(default=None,repr=False)


class AddressReadBody(EmptyBody):
    claim_token: str|None=Field(default=None,min_length=32,max_length=64,repr=False)


class TxidBody(FinancialLeaseBody):
    txid: str=Field(pattern=r'^[0-9a-fA-F]{64}$')


class CorrectionBody(TxidBody):
    reason_code: str=Field(pattern=r'^[A-Z][A-Z0-9_]{2,79}$')


class ReviewBody(EmptyBody):
    reason_code: str=Field(pattern=r'^[A-Z][A-Z0-9_]{2,79}$')


class TakeoverBody(ReviewBody):
    expected_claim_version: int=Field(ge=0,strict=True)
    proof: AdminWalletProofBody|None=Field(default=None,repr=False)


class DecisionBody(TakeoverBody):
    expected_version: int=Field(ge=1,strict=True)


class SelectionBody(TxidBody):
    log_index: int=Field(ge=0,strict=True)
    expected_claim_version: int=Field(ge=0,strict=True)


def create_support_payout_router(settings,factory,*,runtime=None):
    router=APIRouter(prefix='/admin/support-orders/payouts',tags=['support-payout'])
    tokens=TokenService(factory,jwt_secret=settings.jwt_secret or 'development-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer=settings.jwt_issuer,require_session_claims=True)
    def actor(response:Response,authorization:Annotated[str|None,Header()]=None):
        response.headers['Cache-Control']='no-store'
        if not authorization or not authorization.startswith('Bearer '):
            raise AppError(code='AUTH_REQUIRED',message='需要客服管理会话',status_code=401)
        claims=tokens.decode_access_token(authorization[7:])
        if claims.get('session_scope')!='admin':
            raise AppError(code='PERMISSION_DENIED',message='需要客服管理会话',status_code=403)
        if runtime is not None:
            SupportPayoutService(runtime.payouts,settings).order_access.require(claims=claims)
        return claims
    def owner_proof(claims, proof):
        independent=fresh_owner_proof_authorization(settings,factory,runtime.payouts.clock,
            claims,proof,mfa_verifier=runtime.payouts.mfa_verifier)
        grant=(wallet_grant_service(settings,factory,runtime.payouts.clock).authorization(claims=claims)
            if getattr(settings,'wallet_access_grant_enabled',False) else None)
        def authorize(session):
            proof_fresh=independent(session)
            grant_fresh=grant(session) if grant is not None else lambda: None
            def final():
                proof_fresh(); grant_fresh()
            final()
            return final
        return authorize
    def financial_args(body, claims):
        return dict(body.model_dump(exclude={'proof'}),owner_authorize=owner_proof(claims,body.proof))
    def service(*,execution=False):
        if runtime is None or execution and not runtime.payout_execution_enabled:
            raise AppError(code='WALLET_MANUAL_NOT_READY',message='提现处理服务尚未就绪',status_code=503)
        return SupportPayoutService(runtime.payouts,settings)
    @router.get('')
    def listing(limit:Annotated[int,Query(ge=1,le=100)]=50,cursor:str|None=None,claims=Depends(actor)):
        return service().list(claims=claims,limit=limit,cursor=cursor)
    @router.get('/{order_id}')
    def detail(order_id:str,claims=Depends(actor)):
        return service().detail(claims=claims,order_id=order_id)
    @router.post('/{order_id}/claim')
    def claim(order_id:str,body:EmptyBody,idempotency_key:Annotated[str,Header(alias='Idempotency-Key',min_length=1,max_length=128)],claims=Depends(actor)):
        return service(execution=True).claim(claims=claims,order_id=order_id,idempotency_key=idempotency_key)
    @router.post('/{order_id}/heartbeat')
    def heartbeat(order_id:str,body:LeaseBody,claims=Depends(actor)):
        return service().heartbeat(claims=claims,order_id=order_id,claim_token=body.claim_token)
    @router.post('/{order_id}/review-claim')
    def review(order_id:str,body:ReviewBody,idempotency_key:Annotated[str,Header(alias='Idempotency-Key',min_length=1,max_length=128)],claims=Depends(actor)):
        return service(execution=True).review_claim(claims=claims,order_id=order_id,idempotency_key=idempotency_key,reason_code=body.reason_code)
    @router.post('/{order_id}/begin-payment')
    def begin(order_id:str,body:BeginBody,idempotency_key:Annotated[str,Header(alias='Idempotency-Key',min_length=1,max_length=128)],claims=Depends(actor)):
        return service(execution=True).begin_payment(claims=claims,order_id=order_id,idempotency_key=idempotency_key,**financial_args(body,claims))
    @router.post('/{order_id}/adjust-rate')
    def adjust(order_id:str,body:RateBody,idempotency_key:Annotated[str,Header(alias='Idempotency-Key',min_length=1,max_length=128)],claims=Depends(actor)):
        return service(execution=True).adjust_rate(claims=claims,order_id=order_id,idempotency_key=idempotency_key,**financial_args(body,claims))
    @router.post('/{order_id}/cancel-unstarted')
    def cancel_unstarted(order_id:str,body:DecisionBody,idempotency_key:Annotated[str,Header(alias='Idempotency-Key',min_length=1,max_length=128)],claims=Depends(actor)):
        return service().cancel_unstarted(claims=claims,order_id=order_id,idempotency_key=idempotency_key,**financial_args(body,claims))
    @router.post('/{order_id}/stop-for-review')
    def stop_for_review(order_id:str,body:DecisionBody,idempotency_key:Annotated[str,Header(alias='Idempotency-Key',min_length=1,max_length=128)],claims=Depends(actor)):
        return service().stop_for_review(claims=claims,order_id=order_id,idempotency_key=idempotency_key,**financial_args(body,claims))
    @router.post('/{order_id}/reject')
    def reject(order_id:str,body:RejectBody,idempotency_key:Annotated[str,Header(alias='Idempotency-Key',min_length=1,max_length=128)],claims=Depends(actor)):
        payout_service=service(execution=True)
        owner_authorize=None
        if claims['sub']==settings.wallet_manual_owner_admin_id:
            receipt=payout_service.rejection_receipt(claims=claims,order_id=order_id,
                claim_token=body.claim_token,reason_code=body.reason_code,idempotency_key=idempotency_key)
            if receipt is not None:
                return receipt
            owner_authorize=owner_proof(claims,body.proof)
        elif body.proof is not None:
            raise AppError(code='SUPPORT_OWNER_PROOF_NOT_ALLOWED',message='仅官方钱包所有者管理员可使用此证明',status_code=403)
        return payout_service.reject(claims=claims,order_id=order_id,claim_token=body.claim_token,
            reason_code=body.reason_code,idempotency_key=idempotency_key,
            owner_authorize=owner_authorize)
    @router.post('/{order_id}/payment-address/read')
    def payment_address(order_id:str,body:AddressReadBody,claims=Depends(actor)):
        return service().read_payment_address(claims=claims,order_id=order_id,
            claim_token=body.claim_token)
    @router.post('/{order_id}/takeover')
    def takeover(order_id:str,body:TakeoverBody,idempotency_key:Annotated[str,Header(alias='Idempotency-Key',min_length=1,max_length=128)],claims=Depends(actor)):
        payout_service=service()
        args=dict(claims=claims,order_id=order_id,expected_claim_version=body.expected_claim_version,
            reason_code=body.reason_code,idempotency_key=idempotency_key)
        replay=payout_service.takeover_receipt(**args)
        if replay is not None:
            return replay
        owner_authorize=owner_proof(claims,body.proof)
        return payout_service.takeover(**args,owner_authorize=owner_authorize)
    @router.post('/{order_id}/select-discovered')
    def select_discovered(order_id:str,body:SelectionBody,idempotency_key:Annotated[str,Header(alias='Idempotency-Key',min_length=1,max_length=128)],claims=Depends(actor)):
        payout_service=service()
        payout_service.discovery_reader_factory=runtime.new_discovery_reader
        return payout_service.select_discovered(claims=claims,order_id=order_id,
            idempotency_key=idempotency_key,**financial_args(body,claims))
    @router.get('/{order_id}/discover')
    def discover(order_id:str,claims=Depends(actor),
                 claim_token:Annotated[str|None,Header(alias='X-Support-Claim-Token',min_length=32,max_length=64)]=None):
        if runtime is None:
            raise AppError(code='WALLET_MANUAL_NOT_READY',message='提现处理服务尚未就绪',status_code=503)
        payout_service=SupportPayoutService(runtime.payouts,settings,
            discovery_reader_factory=runtime.new_discovery_reader)
        return payout_service.discover(claims=claims,order_id=order_id,claim_token=claim_token)
    @router.post('/{order_id}/txid')
    def txid(order_id:str,body:TxidBody,idempotency_key:Annotated[str,Header(alias='Idempotency-Key',min_length=1,max_length=128)],claims=Depends(actor)):
        return service().submit_txid(claims=claims,order_id=order_id,idempotency_key=idempotency_key,**financial_args(body,claims))
    @router.post('/{order_id}/reconcile')
    def reconcile(order_id:str,body:LeaseBody,idempotency_key:Annotated[str,Header(alias='Idempotency-Key',min_length=1,max_length=128)],claims=Depends(actor)):
        return service().reconcile(claims=claims,order_id=order_id,claim_token=body.claim_token)
    @router.post('/{order_id}/correct-candidate')
    def correction(order_id:str,body:CorrectionBody,idempotency_key:Annotated[str,Header(alias='Idempotency-Key',min_length=1,max_length=128)],claims=Depends(actor)):
        return service().correct_candidate(claims=claims,order_id=order_id,idempotency_key=idempotency_key,**financial_args(body,claims))
    return router
