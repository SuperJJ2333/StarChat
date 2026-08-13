from decimal import Decimal
from typing import Annotated
from fastapi import APIRouter, Depends, Header
from pydantic import BaseModel, ConfigDict, Field
from app.core.config import Settings
from app.core.errors import AppError
from app.integrations.custody.sandbox import SandboxCustodyProvider
from app.modules.identity.rbac import Permission, RbacService
from app.modules.identity.tokens import TokenService
from app.modules.identity.totp import FernetSecretProtector, TotpService
from app.modules.wallet.service import WalletService
import base64, hashlib

class StrictModel(BaseModel): model_config = ConfigDict(extra="forbid")
class WithdrawalBody(StrictModel):
    amount: Decimal = Field(gt=0, decimal_places=6)
    address: str = Field(min_length=1, max_length=128)
    client_order_id: str = Field(min_length=1, max_length=128)
    reason_code: str = Field(min_length=1, max_length=100)
class ApprovalBody(StrictModel): approve: bool = True

def create_wallet_router(settings: Settings, session_factory) -> APIRouter:
    router=APIRouter(prefix="/wallet", tags=["wallet"])
    provider=SandboxCustodyProvider(secret=settings.wallet_webhook_secret or "development-wallet-webhook-secret")
    service=WalletService(session_factory, provider, withdrawal_admin_threshold=Decimal(str(settings.adjustment_admin_threshold)))
    rbac=RbacService(session_factory)
    tokens=TokenService(session_factory,jwt_secret=settings.jwt_secret or "development-jwt-secret-at-least-thirty-two-bytes",jwt_issuer=settings.jwt_issuer)
    key=base64.urlsafe_b64encode(hashlib.sha256((settings.jwt_secret or "development-jwt-secret-at-least-thirty-two-bytes").encode()).digest())
    totp=TotpService(session_factory,protector=FernetSecretProtector(key))
    def actor(authorization: Annotated[str|None, Header()] = None):
        if not authorization or not authorization.startswith("Bearer "): raise AppError(code="AUTH_REQUIRED",message="需要登录",status_code=401)
        return str(tokens.decode_access_token(authorization[7:])["sub"])
    def verify_totp(user_id, code):
        if not code: raise AppError(code="TOTP_REQUIRED",message="需要动态验证码",status_code=403)
        totp.verify(user_id,code)
    @router.get("/balances/me")
    def balance(user_id:str=Depends(actor)): return {"asset":"USDT-TRC20","balance":str(service.usdt_balance(user_id))}
    @router.get("/transactions")
    def history(kind:str|None=None,user_id:str=Depends(actor)): return {"items":service.history(user_id,kind),"next_cursor":None}
    @router.post("/withdrawals",status_code=201)
    def request(body:WithdrawalBody,user_id:str=Depends(actor)): return service.request_withdrawal(user_id=user_id,amount=body.amount,address=body.address,client_order_id=body.client_order_id,reason_code=body.reason_code)
    @router.get("/withdrawals/{withdrawal_id}")
    def status(withdrawal_id:str,user_id:str=Depends(actor)): return service.withdrawal_status(withdrawal_id,user_id)
    @router.post("/withdrawals/{withdrawal_id}/finance-approve")
    def finance(withdrawal_id:str,code:Annotated[str|None,Header(alias="X-TOTP-Code")]=None,user_id:str=Depends(actor)):
        rbac.require(user_id,Permission.FINANCE_REVIEW); verify_totp(user_id,code); return service.finance_approve(withdrawal_id,user_id)
    @router.post("/withdrawals/{withdrawal_id}/admin-approve")
    def admin(withdrawal_id:str,code:Annotated[str|None,Header(alias="X-TOTP-Code")]=None,user_id:str=Depends(actor)):
        rbac.require(user_id,Permission.SUPERVISOR_APPROVE); verify_totp(user_id,code); return service.admin_approve(withdrawal_id,user_id)
    @router.post("/withdrawals/{withdrawal_id}/submit")
    def submit(withdrawal_id:str,code:Annotated[str|None,Header(alias="X-TOTP-Code")]=None,user_id:str=Depends(actor)):
        rbac.require(user_id,Permission.FINANCE_REVIEW); verify_totp(user_id,code); return service.submit_to_custody(withdrawal_id,user_id)
    @router.post("/webhooks/custody")
    def webhook(payload:dict, x_custody_signature:Annotated[str,Header(alias="X-Custody-Signature")]): return {"status":service.handle_deposit_webhook(payload,x_custody_signature)}
    return router
