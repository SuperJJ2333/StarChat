"""ADR-0076：参考汇率展示端点（仅服务端访问上游）。"""
from typing import Annotated

from fastapi import APIRouter, Depends, Header
from pydantic import BaseModel

from app.core.config import Settings
from app.core.errors import AppError
from app.modules.fx.service import FxService
from app.modules.identity.tokens import TokenService


class FxRateResponse(BaseModel):
    pair: str
    rate: str
    fetched_at: str | None
    expires_at: str | None
    stale: bool
    upstream_uptime: str | None
    pricing_basis: str
    disclaimer: str


def create_fx_router(settings: Settings, session_factory) -> APIRouter:
    router = APIRouter(prefix="/fx", tags=["fx"])
    tokens = TokenService(
        session_factory,
        jwt_secret=settings.jwt_secret or "development-jwt-secret-at-least-thirty-two-bytes",
        jwt_issuer=settings.jwt_issuer,
        require_session_claims=settings.environment != "test",
    )

    def actor(authorization: Annotated[str | None, Header()] = None) -> str:
        if not authorization or not authorization.startswith("Bearer "):
            raise AppError(code="AUTH_REQUIRED", message="需要登录", status_code=401)
        return str(tokens.decode_access_token(authorization[7:])["sub"])

    def _service() -> FxService:
        return FxService(
            session_factory,
            api_id=settings.fx_api_id.get_secret_value() if settings.fx_api_id else None,
            api_key=settings.fx_api_key.get_secret_value() if settings.fx_api_key else None,
            api_url=settings.fx_api_url,
            ttl_seconds=settings.fx_cache_ttl_seconds,
        )

    @router.get("/rate", response_model=FxRateResponse)
    def rate(user_id: str = Depends(actor)):
        """点钻↔USDT 参考展示共用同一快照；过期快照标注 stale=true。"""
        snapshot = _service().get_rate_snapshot(actor_id=user_id)
        return FxRateResponse(
            pair=snapshot["pair"],
            rate=str(snapshot["rate"]),
            fetched_at=snapshot["fetched_at"].isoformat() if snapshot["fetched_at"] else None,
            expires_at=snapshot["expires_at"].isoformat() if snapshot["expires_at"] else None,
            stale=snapshot["stale"],
            upstream_uptime=snapshot["upstream_uptime"],
            pricing_basis=snapshot["pricing_basis"],
            disclaimer=snapshot["disclaimer"],
        )

    return router
