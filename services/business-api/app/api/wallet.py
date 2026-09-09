from datetime import datetime
from decimal import Decimal
from typing import Annotated, Literal
from fastapi import APIRouter, Depends, Header, Query
from pydantic import BaseModel, ConfigDict, Field, field_validator
from app.core.config import Settings
from app.core.errors import AppError
from app.integrations.custody.factory import create_custody_provider
from app.modules.identity.rbac import Permission, RbacService
from app.modules.identity.tokens import TokenService
from app.modules.wallet.service import WalletService
from app.api.wallet_binding import create_wallet_binding_router
from app.api.manual_wallet import create_manual_wallet_router
from app.api.official_wallet import create_official_wallet_router

class StrictModel(BaseModel): model_config = ConfigDict(extra="forbid")
class WithdrawalBody(StrictModel):
    amount: Decimal = Field(gt=0, decimal_places=6)
    address: str = Field(min_length=1, max_length=128)
    client_order_id: str = Field(min_length=1, max_length=128)
    reason_code: str = Field(min_length=1, max_length=100)
    @field_validator("amount", mode="before")
    @classmethod
    def decimal_string_only(cls, value):
        if not isinstance(value, str):
            raise ValueError("amount must be a decimal string")
        return value
class ApprovalBody(StrictModel): approve: bool = True
class ConversionBody(StrictModel):
    direction: Literal["USDT_TO_CAIBI", "CAIBI_TO_USDT"]
    amount: str = Field(pattern=r"^(0|[1-9][0-9]*)(\.[0-9]{1,6})?$", max_length=24)

def create_wallet_router(settings: Settings, session_factory, *, custody_provider=None, manual_runtime=None) -> APIRouter:
    router=APIRouter(prefix="/wallet", tags=["wallet"])
    router.include_router(create_official_wallet_router(settings, session_factory))
    router.include_router(create_wallet_binding_router(settings, session_factory,
        service=manual_runtime.binding if manual_runtime is not None else None))
    router.include_router(create_manual_wallet_router(settings, session_factory, runtime=manual_runtime))
    # A04：统一工厂注入——生产未接真实托管时资金入口关闭（fail closed）。
    # custody_provider 允许测试注入 (provider, mode) 元组模拟生产门禁。
    if custody_provider is None:
        custody_provider = create_custody_provider(settings)
    provider, provider_mode = custody_provider
    service=WalletService(
        session_factory,
        provider,
        withdrawal_admin_threshold=Decimal(str(settings.adjustment_admin_threshold)),
        confirmation_threshold=settings.wallet_confirmation_threshold,
        conversions_enabled=(manual_runtime.conversions_enabled if manual_runtime is not None else
            settings.wallet_conversions_enabled and provider is not None and provider_mode == "sandbox" and settings.environment != "production"),
        manual_runtime=manual_runtime,
    )
    rbac=RbacService(session_factory)
    tokens=TokenService(session_factory,jwt_secret=settings.jwt_secret or "development-jwt-secret-at-least-thirty-two-bytes",jwt_issuer=settings.jwt_issuer, require_session_claims=settings.environment != "test")
    def actor(authorization: Annotated[str|None, Header()] = None):
        if not authorization or not authorization.startswith("Bearer "): raise AppError(code="AUTH_REQUIRED",message="需要登录",status_code=401)
        return str(tokens.decode_access_token(authorization[7:])["sub"])
    def require_funding_enabled():
        """生产环境未接真实托管：资金入口明确 503，绝不静默沙箱。"""
        if manual_runtime is not None:
            raise AppError(code='WALLET_LEGACY_FUNDING_DISABLED', message='请升级客户端并使用已绑定钱包资金流程', status_code=503)
        if provider is None:
            raise AppError(code="WALLET_CUSTODY_NOT_CONFIGURED", message="钱包资金功能未接入生产托管服务", status_code=503)

    @router.get("/config")
    def config(user_id:str=Depends(actor)):
        # U03：有效网络/确认阈值/最小金额——客户端展示的统一来源。
        payload = service.config()
        payload["binding_required"] = manual_runtime is not None or settings.environment == "production"
        payload["rebind_interval_days"] = 30
        payload["funding_enabled"] = manual_runtime.deposits_enabled if manual_runtime is not None else provider is not None
        payload['funding_mode'] = 'manual_tron' if manual_runtime is not None else provider_mode
        payload['manual_payout_enabled'] = manual_runtime is not None and manual_runtime.payout_requests_enabled
        payload['manual_payout_execution_enabled'] = manual_runtime is not None and manual_runtime.payout_execution_enabled
        payload['reserve_policy'] = settings.wallet_reserve_policy
        payload['user_auth_mode'] = settings.wallet_user_auth_mode
        if manual_runtime is not None:
            payload.update(withdrawal_fee='0.000000', withdrawal_max_per=str(manual_runtime.payouts.policy.max_per),
                withdrawal_user_24h=str(manual_runtime.payouts.policy.user_24h),
                withdrawal_global_24h=str(manual_runtime.payouts.policy.global_24h))
        payload["conversion_enabled"] = service.conversions_enabled
        return payload

    @router.get("/balances/me")
    def balance(user_id:str=Depends(actor)):
        return {"asset":"USDT-TRC20", "balance":str(service.usdt_balance(user_id)), **service.balances(user_id)}

    @router.post("/conversions", status_code=201)
    def convert(body:ConversionBody, idempotency_key:Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128)], user_id:str=Depends(actor)):
        if manual_runtime is None:
            require_funding_enabled()
        if not service.conversions_enabled:
            raise AppError(code="WALLET_CONVERSION_DISABLED", message="兑换暂未开放", status_code=503)
        try:
            return service.convert(user_id=user_id, direction=body.direction, amount=body.amount,
                                   idempotency_key=idempotency_key)
        except ValueError as error:
            detail = str(error).lower()
            if "conflict" in detail or "idempotency" in detail:
                raise AppError(code="IDEMPOTENCY_CONFLICT", message="该订单号已用于其他请求，请核对原订单", status_code=409) from error
            if "reserve" in detail:
                raise AppError(code="WALLET_RESERVE_INSUFFICIENT", message="兑付储备不足，兑换未执行", status_code=409) from error
            if "restricted" in detail:
                raise AppError(code="WALLET_ACCOUNT_RESTRICTED", message="账户资金操作受限，请联系财务", status_code=403) from error
            if "paused" in detail or "unavailable" in detail:
                raise AppError(code="WALLET_PAUSED", message="钱包已暂停，兑换未执行", status_code=503) from error
            raise AppError(code="WALLET_CONVERSION_REJECTED", message="金额、精度或可用余额不满足兑换条件", status_code=422) from error

    @router.get("/conversions/{conversion_id}")
    def conversion_status(conversion_id:str, user_id:str=Depends(actor)):
        try:
            return service.conversion_status(conversion_id, user_id)
        except ValueError as error:
            raise AppError(code="WALLET_ORDER_NOT_FOUND", message="订单不存在", status_code=404) from error

    @router.post("/withdrawals/{withdrawal_id}/cancel")
    def cancel(withdrawal_id:str, idempotency_key:Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128)], user_id:str=Depends(actor)):
        return service.cancel_withdrawal(withdrawal_id, user_id)

    @router.get("/deposit-address")
    def deposit_address(user_id:str=Depends(actor)):
        require_funding_enabled()
        return {"asset":"USDT-TRC20","network":"TRC20","address":service.deposit_address(user_id)}

    @router.get("/transactions")
    def history(
        kind:str|None=None,
        limit:int=Query(default=50, ge=1, le=100),
        cursor:str|None=None,
        user_id:str=Depends(actor),
    ):
        # F07：稳定游标分页（created_at|id）；服务端最大页长 100。
        parsed = None
        if cursor:
            try:
                created_at, _, row_id = cursor.partition("|")
                parsed = (datetime.fromisoformat(created_at), row_id)
            except ValueError:
                raise AppError(code="WALLET_CURSOR_INVALID", message="分页游标无效", status_code=400)
        items, next_cursor = service.history(user_id, kind, limit=limit, cursor=parsed)
        return {"items": items, "next_cursor": next_cursor}

    @router.post("/withdrawals",status_code=201)
    def request(body:WithdrawalBody, idempotency_key:Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128)], user_id:str=Depends(actor)):
        require_funding_enabled()
        if idempotency_key != body.client_order_id:
            raise AppError(code="IDEMPOTENCY_CONFLICT", message="提现请求键不一致", status_code=409)
        try:
            return service.request_withdrawal(user_id=user_id,amount=body.amount,address=body.address,client_order_id=body.client_order_id,reason_code=body.reason_code)
        except ValueError as error:
            if str(error) == "withdrawal client order id reused with different payload":
                raise AppError(code="WALLET_ORDER_CONFLICT", message="该订单号已用于不同的提现请求", status_code=409) from error
            raise
    @router.get("/withdrawals/{withdrawal_id}")
    def status(withdrawal_id:str,user_id:str=Depends(actor)): return service.withdrawal_status(withdrawal_id,user_id)
    @router.post("/withdrawals/{withdrawal_id}/finance-approve")
    def finance(withdrawal_id:str,user_id:str=Depends(actor)):
        rbac.require(user_id,Permission.SYSTEM_ADMIN); return service.finance_approve(withdrawal_id,user_id)
    @router.post("/withdrawals/{withdrawal_id}/admin-approve")
    def admin(withdrawal_id:str,user_id:str=Depends(actor)):
        rbac.require(user_id,Permission.SYSTEM_ADMIN); return service.admin_approve(withdrawal_id,user_id)
    @router.post("/withdrawals/{withdrawal_id}/submit")
    def submit(withdrawal_id:str,user_id:str=Depends(actor)):
        rbac.require(user_id,Permission.SYSTEM_ADMIN)
        require_funding_enabled()
        return service.submit_to_custody(withdrawal_id,user_id)

    @router.post("/webhooks/custody")
    def webhook(payload:dict, x_custody_signature:Annotated[str,Header(alias="X-Custody-Signature")]):
        # A02：按白名单事件类型分发到对应处理器（各自完成统一验签与
        # 结构校验）；不支持的事件类型返回稳定错误。生产未接托管时
        # 不存在合法回调来源 → 503。
        require_funding_enabled()
        event_type = payload.get("type") if isinstance(payload, dict) else None
        if event_type == "DEPOSIT_CONFIRMED":
            return {"status":service.handle_deposit_webhook(payload,x_custody_signature)}
        if event_type == "WITHDRAWAL_STATUS":
            return {"status":service.handle_withdrawal_webhook(payload,x_custody_signature)}
        raise AppError(code="CUSTODY_EVENT_UNSUPPORTED", message="不支持的托管事件类型", status_code=400)
    return router
