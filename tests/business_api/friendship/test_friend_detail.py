"""GET /friends/{friend_id}：单个好友详情（任意入口的资料页自取数据）。

覆盖：鉴权；好友返回完整字段（含 last_seen_at 键）；非好友 404；
设备活跃更新后 last_seen_at 随之变化。
"""

from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.main import create_app
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import Device, User
from app.modules.identity.tokens import TokenService
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

JWT_SECRET = "test-jwt-secret-at-least-thirty-two-bytes"


def _settings() -> Settings:
    return Settings(
        _env_file=None,
        environment="test",
        database_url="sqlite+pysqlite:///:memory:",
        redis_url="redis://localhost:6379/15",
        jwt_secret=JWT_SECRET,
    )


def _token(factory, user_id: str) -> str:
    return (
        TokenService(factory, jwt_secret=JWT_SECRET, jwt_issuer="liuhetong")
        .issue_pair(
            user_id=user_id,
            device_key=f"device-{user_id}",
            display_name="detail test device",
        )
        .access_token
    )


@pytest.fixture()
def detail_components():
    engine = create_engine(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        for uid, name in [("me", "me"), ("friend", "friend"), ("stranger", "stranger")]:
            session.add(
                User(
                    id=uid,
                    username=name,
                    username_normalized=name,
                    email=f"{name}@example.com",
                    email_normalized=f"{name}@example.com",
                    password_hash="hash",
                    status=AccountStatus.ACTIVE,
                    email_verified_at=now,
                    created_at=now,
                    updated_at=now,
                    matrix_user_id=f"@{name}:matrix.localhost",
                )
            )
        # me ↔ friend 是好友；stranger 无关系。
        from app.modules.friendship.models import Friendship

        low, high = sorted(["me", "friend"])
        from uuid import uuid4

        session.add(
            Friendship(
                id=str(uuid4()),
                user_low_id=low,
                user_high_id=high,
                created_at=now,
            )
        )
        session.add(
            Device(
                id="dev-friend",
                user_id="friend",
                device_key="friend-device",
                display_name="friend phone",
                created_at=now,
                last_seen_at=now - timedelta(minutes=5),
                revoked_at=None,
            )
        )
    app = create_app(_settings(), session_factory=factory)
    with TestClient(app) as client:
        yield client, factory
    engine.dispose()


def test_detail_requires_auth(detail_components) -> None:
    client, _ = detail_components
    response = client.get("/api/v1/friends/friend")
    assert response.status_code == 401


def test_detail_returns_friend_with_last_seen(detail_components) -> None:
    client, factory = detail_components
    auth = {"Authorization": f"Bearer {_token(factory, 'me')}"}
    response = client.get("/api/v1/friends/friend", headers=auth)
    assert response.status_code == 200
    body = response.json()
    assert body["user_id"] == "friend"
    assert body["username"] == "friend"
    assert "last_seen_at" in body
    assert body["last_seen_at"] is not None


def test_detail_not_friend_returns_404(detail_components) -> None:
    client, factory = detail_components
    auth = {"Authorization": f"Bearer {_token(factory, 'me')}"}
    response = client.get("/api/v1/friends/stranger", headers=auth)
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "FRIEND_NOT_FOUND"


def test_detail_reflects_device_activity(detail_components) -> None:
    client, factory = detail_components
    auth = {"Authorization": f"Bearer {_token(factory, 'me')}"}
    before = client.get("/api/v1/friends/friend", headers=auth).json()
    fresh = datetime.now(timezone.utc)
    with factory.begin() as session:
        device = session.get(Device, "dev-friend")
        device.last_seen_at = fresh
    after = client.get("/api/v1/friends/friend", headers=auth).json()
    assert after["last_seen_at"] != before["last_seen_at"]
    assert after["last_seen_at"].startswith(fresh.isoformat()[:19])
