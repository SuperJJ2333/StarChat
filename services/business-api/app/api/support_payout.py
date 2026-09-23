"""Management-session support payout queue; all financial proof is scope-bound."""
from typing import Annotated
from fastapi import APIRouter, Depends, Header, Query, Response
from pydantic import BaseModel, ConfigDict, Field
from app.core.errors import AppError
from app.modules.identity.tokens import TokenService
from app.modules.wallet.support_payout import SupportPayoutService


class EmptyBody(BaseModel):
    model_config=ConfigDict(extra='forbid')


class LeaseBody(EmptyBody):
    claim_token: str=Field(min_length=32,max_length=64,repr=False)


class BeginBody(LeaseBody):
    expected_digest: str=Field(pattern=r'^[0-9a-f]{64}$')


class RateBody(LeaseBody):
    new_rate: str=Field(pattern=r'^(0|[1-9][0-9]{0,3})(\.[0-9]{1,6})?$')
    reason_code: str=Field(min_length=3,max_length=100)


class TxidBody(LeaseBody):
    txid: str=Field(pattern=r'^[0-9a-fA-F]{64}$')


class CorrectionBody(TxidBody):
    reason_code: str=Field(pattern=r'^[A-Z][A-Z0-9_]{2,79}$')


class ReviewBody(EmptyBody):
    reason_code: str=Field(pattern=r'^[A-Z][A-Z0-9_]{2,79}$')


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
        return claims
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
        return service(execution=True).begin_payment(claims=claims,order_id=order_id,idempotency_key=idempotency_key,**body.model_dump())
    @router.post('/{order_id}/adjust-rate')
    def adjust(order_id:str,body:RateBody,idempotency_key:Annotated[str,Header(alias='Idempotency-Key',min_length=1,max_length=128)],claims=Depends(actor)):
        return service(execution=True).adjust_rate(claims=claims,order_id=order_id,idempotency_key=idempotency_key,**body.model_dump())
    @router.post('/{order_id}/txid')
    def txid(order_id:str,body:TxidBody,idempotency_key:Annotated[str,Header(alias='Idempotency-Key',min_length=1,max_length=128)],claims=Depends(actor)):
        return service().submit_txid(claims=claims,order_id=order_id,idempotency_key=idempotency_key,**body.model_dump())
    @router.post('/{order_id}/reconcile')
    def reconcile(order_id:str,body:LeaseBody,idempotency_key:Annotated[str,Header(alias='Idempotency-Key',min_length=1,max_length=128)],claims=Depends(actor)):
        return service().reconcile(claims=claims,order_id=order_id,claim_token=body.claim_token)
    @router.post('/{order_id}/correct-candidate')
    def correction(order_id:str,body:CorrectionBody,idempotency_key:Annotated[str,Header(alias='Idempotency-Key',min_length=1,max_length=128)],claims=Depends(actor)):
        return service().correct_candidate(claims=claims,order_id=order_id,idempotency_key=idempotency_key,**body.model_dump())
    return router
