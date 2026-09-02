"""邀请码校验接口 reason 契约测试（BUG 1）。

`POST /api/v1/invitations/validate` 返回 `{valid, reason}`，
reason ∈ OK / INVALID / EXPIRED / EXHAUSTED，客户端据此区分失效形态。
"""

from datetime import datetime, timedelta, timezone
from httpx import ASGITransport, AsyncClient
import pytest
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.main import create_app
from app.modules.identity.invitations import InvitationService

JWT_SECRET = "test-jwt-secret-at-least-thirty-two-bytes"


@pytest.fixture()
def validate_components():
    engine = create_engine(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    InvitationService(factory).issue(
        code="LIVE-CODE",
        max_uses=1,
        expires_at=now + timedelta(days=1),
        created_by="admin-1",
    )
    InvitationService(factory).issue(
        code="SPENT-CODE",
        max_uses=1,
        expires_at=now + timedelta(days=1),
        created_by="admin-1",
    )
    with factory.begin() as session:
        # 立即消耗 SPENT-CODE 唯一次数 → EXHAUSTED
        InvitationService(factory).consume_in_session(
            session, code="SPENT-CODE", now=now
        )
    InvitationService(factory).issue(
        code="OLD-CODE",
        max_uses=5,
        expires_at=now - timedelta(days=1),
        created_by="admin-1",
    )
    settings = Settings(
        _env_file=None,
        environment="test",
        database_url="sqlite+pysqlite:///:memory:",
        redis_url="redis://localhost:6379/15",
        jwt_secret=JWT_SECRET,
        email_verification_secret="test-email-verification-secret",
        password_reset_secret="test-password-reset-secret",
    )
    yield create_app(settings, session_factory=factory)
    engine.dispose()


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("code", "valid", "reason"),
    [
        ("LIVE-CODE", True, "OK"),
        ("NO-SUCH-CODE", False, "INVALID"),
        ("OLD-CODE", False, "EXPIRED"),
        ("SPENT-CODE", False, "EXHAUSTED"),
    ],
)
async def test_validate_returns_reason(validate_components, code, valid, reason) -> None:
    async with AsyncClient(
        transport=ASGITransport(app=validate_components), base_url="http://test"
    ) as client:
        response = await client.post(
            "/api/v1/invitations/validate",
            json={"invitation_code": code},
        )
    assert response.status_code == 200
    body = response.json()
    assert body["valid"] is valid
    assert body["reason"] == reason
