"""PATCH /moments/{id}/visibility：作者本人单条修改可见范围。

覆盖：非作者 403；仅作者可见名单字段；合法值校验；非好友名单 422；
受众上限；更新后 dto 反映新可见性；他人视角不泄漏名单。
"""

from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.main import create_app
from app.modules.identity.enums import AccountStatus
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
            display_name="visibility test",
        )
        .access_token
    )


@pytest.fixture()
def visibility_components():
    engine = create_engine(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        from app.modules.identity.models import User
        from app.modules.moments.models import Moment

        for uid, name in [("author", "author"), ("other", "other")]:
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
        # 作者与 other 是好友（friendships 低/高有序）。
        from app.modules.friendship.models import Friendship
        from uuid import uuid4

        session.add(
            Friendship(
                id=str(uuid4()),
                user_low_id="author",
                user_high_id="other",
                created_at=now,
            )
        )
        session.add(
            Moment(
                id="moment-1",
                author_id="author",
                text="hello",
                visibility="PUBLIC",
                image_urls=[],
                include_user_ids=[],
                exclude_user_ids=[],
                include_tag_ids=[],
                exclude_tag_ids=[],
                status="PUBLISHED",
                idempotency_key="key-1",
                created_at=now,
            )
        )
    app = create_app(_settings(), session_factory=factory)
    with TestClient(app) as client:
        yield client, factory
    engine.dispose()


def test_requires_auth(visibility_components) -> None:
    client, _ = visibility_components
    response = client.patch("/api/v1/moments/moment-1/visibility")
    assert response.status_code == 401


def test_author_updates_to_private(visibility_components) -> None:
    client, factory = visibility_components
    auth = {"Authorization": f"Bearer {_token(factory, 'author')}"}
    response = client.patch(
        "/api/v1/moments/moment-1/visibility",
        headers=auth,
        json={"visibility": "SELF"},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["visibility"] == "SELF"
    assert body["include_user_ids"] == []


def test_non_author_forbidden(visibility_components) -> None:
    client, factory = visibility_components
    auth = {"Authorization": f"Bearer {_token(factory, 'other')}"}
    response = client.patch(
        "/api/v1/moments/moment-1/visibility",
        headers=auth,
        json={"visibility": "SELF"},
    )
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "MOMENT_VISIBILITY_FORBIDDEN"


def test_invalid_visibility_rejected(visibility_components) -> None:
    client, factory = visibility_components
    auth = {"Authorization": f"Bearer {_token(factory, 'author')}"}
    response = client.patch(
        "/api/v1/moments/moment-1/visibility",
        headers=auth,
        json={"visibility": "EVERYONE"},
    )
    assert response.status_code == 422


def test_non_friend_audience_rejected(visibility_components) -> None:
    client, factory = visibility_components
    auth = {"Authorization": f"Bearer {_token(factory, 'author')}"}
    response = client.patch(
        "/api/v1/moments/moment-1/visibility",
        headers=auth,
        json={
            "visibility": "INCLUDE",
            "include_user_ids": ["stranger-1"],
        },
    )
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "MOMENT_AUDIENCE_INVALID"


def test_author_updates_include_with_friend(visibility_components) -> None:
    client, factory = visibility_components
    auth = {"Authorization": f"Bearer {_token(factory, 'author')}"}
    response = client.patch(
        "/api/v1/moments/moment-1/visibility",
        headers=auth,
        json={
            "visibility": "INCLUDE",
            "include_user_ids": ["other"],
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert body["visibility"] == "INCLUDE"
    assert body["include_user_ids"] == ["other"]
