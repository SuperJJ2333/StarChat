"""BUG 2 群成员非好友：按 matrix_user_id 反查用户资料与关系状态。

覆盖：
- 陌生人 → 200 + relationship_state=NONE（群成员页可进资料页发申请）；
- 好友 → FRIEND；
- 拉黑双向 / 自己 / 不存在的 mxid → 404（与搜索隐私口径一致）；
- 未登录 → 401。
"""

from datetime import datetime, timezone

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.main import create_app
from app.modules.friendship.models import Friendship, UserBlock
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User
from app.modules.identity.tokens import TokenService

JWT_SECRET = "test-jwt-secret-at-least-thirty-two-bytes"


def _settings() -> Settings:
    return Settings(
        _env_file=None,
        environment="test",
        database_url="sqlite+pysqlite:///:memory:",
        redis_url="redis://localhost:6379/15",
        jwt_secret=JWT_SECRET,
        email_verification_secret="test-email-verification-secret",
        password_reset_secret="test-password-reset-secret",
        referral_code_secret="test-referral-code-secret-32-bytes-min",
    )


def _token(factory, user_id: str) -> str:
    return (
        TokenService(
            factory,
            jwt_secret=JWT_SECRET,
            jwt_issuer="liuhetong",
        )
        .issue_pair(
            user_id=user_id,
            device_key=f"device-{user_id}",
            display_name="Member lookup test device",
        )
        .access_token
    )


@pytest.fixture()
def lookup_components():
    engine = create_engine(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        for user_id in ("alice", "bob", "carol", "dave"):
            session.add(
                User(
                    id=user_id,
                    username=user_id,
                    username_normalized=user_id,
                    email=f"{user_id}@example.com",
                    email_normalized=f"{user_id}@example.com",
                    password_hash="hash",
                    status=AccountStatus.ACTIVE,
                    email_verified_at=now,
                    # dave 是未开通 Matrix 账号的老用户。
                    matrix_user_id=None if user_id == "dave" else f"@{user_id}:matrix.test",
                    created_at=now,
                    updated_at=now,
                )
            )
        # alice-bob 好友；alice 拉黑 carol。
        low, high = sorted(("alice", "bob"))
        session.add(Friendship(id="fr-1", user_low_id=low, user_high_id=high, created_at=now))
        session.add(UserBlock(id="blk-1", blocker_id="alice", blocked_id="carol", idempotency_key="blk-key-1", created_at=now))
    settings = _settings()
    yield create_app(settings, session_factory=factory), factory
    engine.dispose()


async def _get(app, factory, viewer: str, mxid: str):
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        return await client.get(
            "/api/v1/users/lookup",
            params={"matrix_user_id": mxid},
            headers={"Authorization": f"Bearer {_token(factory, viewer)}"},
        )


@pytest.mark.asyncio
async def test_lookup_friend_returns_friend_state(lookup_components) -> None:
    app, factory = lookup_components
    response = await _get(app, factory, "alice", "@bob:matrix.test")
    assert response.status_code == 200
    body = response.json()
    assert body["user_id"] == "bob"
    assert body["username"] == "bob"
    assert body["matrix_user_id"] == "@bob:matrix.test"
    assert body["relationship_state"] == "FRIEND"


@pytest.mark.asyncio
async def test_lookup_stranger_member_returns_none_state(lookup_components) -> None:
    app, factory = lookup_components
    # dave 无 mxid；carol 被 alice 拉黑。bob 视角查 carol（陌生群员）。
    response = await _get(app, factory, "bob", "@carol:matrix.test")
    assert response.status_code == 200
    body = response.json()
    assert body["user_id"] == "carol"
    assert body["relationship_state"] == "NONE"


@pytest.mark.asyncio
async def test_lookup_blocked_self_and_missing_return_404(lookup_components) -> None:
    app, factory = lookup_components
    blocked = await _get(app, factory, "alice", "@carol:matrix.test")
    assert blocked.status_code == 404
    myself = await _get(app, factory, "alice", "@alice:matrix.test")
    assert myself.status_code == 404
    missing = await _get(app, factory, "alice", "@nobody:matrix.test")
    assert missing.status_code == 404


@pytest.mark.asyncio
async def test_lookup_requires_auth(lookup_components) -> None:
    app, _ = lookup_components
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(
            "/api/v1/users/lookup", params={"matrix_user_id": "@bob:matrix.test"})
    assert response.status_code == 401
