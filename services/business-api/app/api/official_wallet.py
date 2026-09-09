"""Authenticated read-only official address display, independent of custody."""
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Header, Response
from pydantic import BaseModel

from app.core.errors import AppError
from app.integrations.tron.message_signature import canonical_address
from app.modules.identity.tokens import TokenService


class OfficialWalletAddress(BaseModel):
    address: str
    asset: Literal['USDT']
    network: Literal['TRC20']
    minimum_deposit: Literal['10.000000']
    funding_enabled: bool
    notice: str


def create_official_wallet_router(settings, factory):
    router = APIRouter(tags=['wallet'])
    tokens = TokenService(factory,
        jwt_secret=settings.jwt_secret or 'development-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer=settings.jwt_issuer, require_session_claims=True)

    def actor(authorization: Annotated[str | None, Header()] = None):
        if not authorization or not authorization.startswith('Bearer '):
            raise AppError(code='AUTH_REQUIRED', message='需要登录', status_code=401)
        return tokens.decode_access_token(authorization[7:])

    @router.get('/official-deposit-address', response_model=OfficialWalletAddress)
    def address(response: Response, identity=Depends(actor)):
        configured = getattr(settings, 'wallet_official_address', None)
        try:
            official = canonical_address(configured.get_secret_value() if configured else None)
        except ValueError:
            raise AppError(code='WALLET_OFFICIAL_ADDRESS_UNAVAILABLE',
                message='官方充值地址尚未配置，请联系客服核实。', status_code=503) from None
        gate = getattr(settings, 'wallet_deposits_enabled', None)
        if gate is None:
            gate = getattr(settings, 'wallet_real_funds_enabled', False)
        enabled = getattr(settings, 'wallet_real_mode', 'disabled') == 'manual_tron' and gate is True
        response.headers['Cache-Control'] = 'no-store'
        response.headers['X-Content-Type-Options'] = 'nosniff'
        return dict(address=official, asset='USDT', network='TRC20', minimum_deposit='10.000000',
            funding_enabled=enabled, notice=(
                '请先完成私人钱包绑定并创建充值意图，再从已绑定地址转入官方钱包。'
                if enabled else '充值入账尚未开放，请勿转账。此处仅展示官方钱包地址。'))

    return router
