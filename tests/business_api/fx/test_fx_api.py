"""ADR-0076：/api/v1/fx/rate 端点（登录态、脱敏、stale 标注）。"""
from datetime import datetime, timedelta, timezone
from decimal import Decimal

from httpx import ASGITransport, AsyncClient
import pytest
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

import app.modules.fx.models  # noqa: F401
from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.main import create_app
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.tokens import TokenService


class FakeUpstream:
    def __init__(self, payload=None):
        self.calls = 0
        self.payload = payload or {"code": 200, "rate": "7.12", "money": 10, "from": "USD", "to": "CNY"}

    def __call__(self, url, timeout):
        self.calls += 1
        return self.payload


@pytest.fixture()
def fx_app():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(
            User(
                id="fx-user",
                username="fxuser",
                username_normalized="fxuser",
                email="fx@example.com",
                email_normalized="fx@example.com",
                password_hash=PasswordHasher().hash("correct horse battery staple"),
                status=AccountStatus.ACTIVE,
                matrix_user_id="@fxuser:matrix.localhost",
                email_verified_at=now,
                created_at=now,
                updated_at=now,
            )
        )
    settings = Settings(
        _env_file=None,
        environment="test",
        database_url="sqlite+pysqlite:///:memory:",
        redis_url="redis://localhost:6379/15",
        jwt_secret="test-jwt-secret-at-least-thirty-two-bytes",
        email_verification_secret="test-email-verification-secret",
        password_reset_secret="test-password-reset-secret",
        fx_api_id="cfg-id",
        fx_api_key="cfg-key",
    )
    app = create_app(settings, session_factory=factory)
    tokens = TokenService(factory, jwt_secret=settings.jwt_secret, jwt_issuer=settings.jwt_issuer, require_session_claims=False)
    pair = tokens.issue_pair(user_id="fx-user", device_key="device-1", display_name="test")
    yield app, factory, pair.access_token
    engine.dispose()


@pytest.mark.asyncio
async def test_fx_rate_requires_authentication(fx_app):
    app, _, _ = fx_app
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/api/v1/fx/rate")
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "AUTH_REQUIRED"


@pytest.mark.asyncio
async def test_fx_rate_returns_snapshot_with_disclaimer(fx_app):
    app, factory, token = fx_app
    from app.modules.fx.service import FxService

    upstream = FakeUpstream()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        # 注入受控上游（服务按请求即时装配，替换其 http_get）
        original_get_rate = FxService.get_rate_snapshot

        def patched(self, *, actor_id):
            self.http_get = upstream
            return original_get_rate(self, actor_id=actor_id)

        FxService.get_rate_snapshot = patched
        try:
            response = await client.get("/api/v1/fx/rate", headers={"Authorization": f"Bearer {token}"})
        finally:
            FxService.get_rate_snapshot = original_get_rate
    assert response.status_code == 200
    body = response.json()
    assert body["pair"] == "USD/CNY"
    assert Decimal(body["rate"]) == Decimal("7.120000")
    assert body["stale"] is False
    assert body["disclaimer"] == "参考估算，最终以客服结算为准"
    assert body["pricing_basis"].startswith("1 USDT ≈ 1 USD")
    assert upstream.calls == 1
