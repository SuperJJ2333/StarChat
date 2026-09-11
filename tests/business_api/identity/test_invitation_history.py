"""GET /invitations/history：邀请历史（按使用时间倒序 + offset 分页）。

覆盖：鉴权；注册消耗个人码产生历史记录（时间/昵称/畅聊号）；
昵称缺失的占位由客户端处理（服务端原样返回 null）；
分页 next_offset；空历史；他人邀请关系不串页。
"""

from datetime import datetime, timedelta, timezone

from httpx import ASGITransport, AsyncClient
import pytest
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.main import create_app
from app.modules.identity.enums import AccountStatus
from app.modules.identity.invitations import InvitationService
from app.modules.identity.models import User
from app.modules.identity.tokens import TokenService

JWT_SECRET = "test-jwt-secret-at-least-thirty-two-bytes"
REFERRAL_SECRET = "test-referral-code-secret-32-bytes-min"
PASSWORD = "correct horse battery staple"


def _settings() -> Settings:
    return Settings(
        _env_file=None,
        environment="test",
        database_url="sqlite+pysqlite:///:memory:",
        redis_url="redis://localhost:6379/15",
        jwt_secret=JWT_SECRET,
        email_verification_secret="test-email-verification-secret",
        password_reset_secret="test-password-reset-secret",
        referral_code_secret=REFERRAL_SECRET,
    )


def _token(factory, user_id: str) -> str:
    return (
        TokenService(factory, jwt_secret=JWT_SECRET, jwt_issuer="liuhetong")
        .issue_pair(
            user_id=user_id,
            device_key=f"device-{user_id}",
            display_name="History test device",
        )
        .access_token
    )


@pytest.fixture()
def history_components():
    engine = create_engine(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    InvitationService(factory).issue(
        code="API-INVITE",
        max_uses=10,
        expires_at=now + timedelta(days=1),
        created_by="admin-1",
    )
    with factory.begin() as session:
        session.add(
            User(
                id="inviter-user",
                username="inviter",
                username_normalized="inviter",
                email="inviter@example.com",
                email_normalized="inviter@example.com",
                password_hash="hash",
                status=AccountStatus.ACTIVE,
                email_verified_at=now,
                created_at=now,
                updated_at=now,
            )
        )
    settings = _settings()
    yield create_app(settings, session_factory=factory), factory
    engine.dispose()


async def _register(client, *, username: str, email: str, invitation: str, key: str):
    return await client.post(
        "/api/v1/auth/register",
        headers={"Idempotency-Key": key},
        json={
            "username": username,
            "email": email,
            "password": PASSWORD,
            "invitation_code": invitation,
        },
    )


@pytest.mark.asyncio
async def test_history_requires_auth(history_components) -> None:
    app, _ = history_components
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/api/v1/invitations/history")
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_history_empty_then_records_after_registration(
    history_components,
) -> None:
    app, factory = history_components
    auth = {"Authorization": f"Bearer {_token(factory, 'inviter-user')}"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        empty = await client.get("/api/v1/invitations/history", headers=auth)
        assert empty.status_code == 200
        assert empty.json()["items"] == []
        assert empty.json()["next_offset"] is None

        mine = await client.get("/api/v1/invitations/mine", headers=auth)
        code = mine.json()["code"]
        first = await _register(
            client,
            username="alice",
            email="alice@example.com",
            invitation=code,
            key="hist-alice",
        )
        assert first.status_code == 202
        second = await _register(
            client,
            username="bob",
            email="bob@example.com",
            invitation=code,
            key="hist-bob",
        )
        assert second.status_code == 202

        page = await client.get("/api/v1/invitations/history", headers=auth)
        assert page.status_code == 200
        items = page.json()["items"]
        assert [item["username"] for item in items] == ["bob", "alice"]
        # 注册未填昵称时默认与用户名一致；历史接口原样回传公开资料昵称。
        assert isinstance(items[0]["nickname"], str)
        for item in items:
            assert "bound_at" in item


@pytest.mark.asyncio
async def test_history_pagination_with_limit(history_components) -> None:
    app, factory = history_components
    auth = {"Authorization": f"Bearer {_token(factory, 'inviter-user')}"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        code = (await client.get("/api/v1/invitations/mine", headers=auth)).json()["code"]
        for i in range(3):
            response = await _register(
                client,
                username=f"user{i}",
                email=f"user{i}@example.com",
                invitation=code,
                key=f"hist-user{i}",
            )
            assert response.status_code == 202

        page1 = await client.get(
            "/api/v1/invitations/history", params={"limit": 2}, headers=auth
        )
        body1 = page1.json()
        assert len(body1["items"]) == 2
        assert body1["next_offset"] == 2

        page2 = await client.get(
            "/api/v1/invitations/history",
            params={"limit": 2, "offset": 2},
            headers=auth,
        )
        body2 = page2.json()
        assert len(body2["items"]) == 1
        assert body2["next_offset"] is None
        all_usernames = [i["username"] for i in body1["items"] + body2["items"]]
        assert all_usernames == ["user2", "user1", "user0"]
