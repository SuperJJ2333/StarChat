"""好友系统重构 Phase B/E 后端测试。

覆盖：
- DELETE /friends/requests/{id}：申请人撤销（PENDING → CANCELLED）、
  非本人/已处理/幂等重放；
- GET /friends/requests 返回 remark/tags/user_id（通过朋友验证页数据）；
- Canonical Direct Conversation：查询复用、注册、并发冲突返回既有行、
  自对拒绝、鉴权。
"""

from datetime import datetime, timedelta, timezone
from uuid import uuid4

from httpx import ASGITransport, AsyncClient
import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.pool import StaticPool

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.main import create_app
from app.modules.friendship.models import DirectConversation, FriendRequest
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User
from app.modules.identity.tokens import TokenService

JWT_SECRET = "test-jwt-secret-at-least-thirty-two-bytes"
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
            display_name="Friend refactor test device",
        )
        .access_token
    )


@pytest.fixture()
def friend_components():
    engine = create_engine(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        for user_id, username in [
            ("alice", "alice"),
            ("bob", "bob"),
            ("carol", "carol"),
        ]:
            session.add(
                User(
                    id=user_id,
                    username=username,
                    username_normalized=username,
                    email=f"{username}@example.com",
                    email_normalized=f"{username}@example.com",
                    password_hash="hash",
                    status=AccountStatus.ACTIVE,
                    email_verified_at=now,
                    created_at=now,
                    updated_at=now,
                )
            )
        session.add(
            FriendRequest(
                id="req-1",
                requester_id="bob",
                target_id="alice",
                message="你好，我是Bob",
                status="PENDING",
                idempotency_key="seed-1",
                created_at=now,
                requested_at=now,
                contact_remark="同事",
                contact_tags="工作,朋友",
            )
        )
    settings = _settings()
    yield create_app(settings, session_factory=factory), factory
    engine.dispose()


@pytest.mark.asyncio
async def test_cancel_own_pending_request(friend_components) -> None:
    app, factory = friend_components
    auth = {"Authorization": f"Bearer {_token(factory, 'bob')}",
            "Idempotency-Key": "cancel-1"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.delete("/api/v1/friends/requests/req-1", headers=auth)
    assert response.status_code == 200
    assert response.json()["status"] == "CANCELLED"
    # 幂等重放：同键返回同状态。
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        replay = await client.delete("/api/v1/friends/requests/req-1", headers=auth)
    assert replay.status_code == 200
    assert replay.json()["status"] == "CANCELLED"


@pytest.mark.asyncio
async def test_cancel_rejects_non_owner(friend_components) -> None:
    app, factory = friend_components
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.delete(
            "/api/v1/friends/requests/req-1",
            headers={
                "Authorization": f"Bearer {_token(factory, 'alice')}",
                "Idempotency-Key": "cancel-alice-1",
            },
        )
    assert response.status_code == 404


@pytest.mark.asyncio
async def test_cancel_rejects_resolved_request(friend_components) -> None:
    app, factory = friend_components
    with factory.begin() as session:
        row = session.get(FriendRequest, "req-1")
        row.status = "REJECTED"
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.delete(
            "/api/v1/friends/requests/req-1",
            headers={
                "Authorization": f"Bearer {_token(factory, 'bob')}",
                "Idempotency-Key": "cancel-late-1",
            },
        )
    assert response.status_code == 409


@pytest.mark.asyncio
async def test_requests_list_carries_public_review_fields_only(friend_components) -> None:
    app, factory = friend_components
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(
            "/api/v1/friends/requests",
            headers={"Authorization": f"Bearer {_token(factory, 'alice')}"},
        )
    assert response.status_code == 200
    item = response.json()["items"][0]
    assert item["user_id"] == "bob"
    assert item["remark"] is None
    assert item["tags"] == []
    assert item["message"] == "你好，我是Bob"


@pytest.mark.asyncio
async def test_direct_conversation_resolve_and_register(friend_components) -> None:
    app, factory = friend_components
    alice = {"Authorization": f"Bearer {_token(factory, 'alice')}"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        # 未注册 → null（创建前先查询）。
        empty = await client.get(
            "/api/v1/direct-conversations", params={"peer_user_id": "bob"}, headers=alice)
        assert empty.status_code == 200
        assert empty.json()["matrix_room_id"] is None
        # 注册 → 规范房间。
        register = await client.post(
            "/api/v1/direct-conversations",
            headers={**alice, "Idempotency-Key": "register-1"},
            json={"peer_user_id": "bob", "matrix_room_id": "!room-a:test"})
        assert register.status_code == 200
        assert register.json() == {"matrix_room_id": "!room-a:test", "existing": False}
        # 再次查询 → 复用既有房间；对端视角同样复用。
        for viewer in ("alice", "bob"):
            resolved = await client.get(
                "/api/v1/direct-conversations",
                params={"peer_user_id": "bob" if viewer == "alice" else "alice"},
                headers={"Authorization": f"Bearer {_token(factory, viewer)}"})
            assert resolved.json()["matrix_room_id"] == "!room-a:test"
        # 并发冲突：另一方注册不同房间 → 返回既有行。
        conflict = await client.post(
            "/api/v1/direct-conversations",
            headers={
                "Authorization": f"Bearer {_token(factory, 'bob')}",
                "Idempotency-Key": "register-bob-1",
            },
            json={"peer_user_id": "alice", "matrix_room_id": "!room-b:test"})
        assert conflict.status_code == 200
        assert conflict.json() == {"matrix_room_id": "!room-b:test", "existing": True}
    # 数据库：每对好友仅一行（以 bob 的更新为准）。
    with factory() as session:
        rows = list(session.scalars(select(DirectConversation)).all())
        assert len(rows) == 1
        assert rows[0].matrix_room_id == "!room-b:test"
        assert {rows[0].user_low_id, rows[0].user_high_id} == {"alice", "bob"}


@pytest.mark.asyncio
async def test_direct_conversation_self_and_auth(friend_components) -> None:
    app, factory = friend_components
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        unauthenticated = await client.get(
            "/api/v1/direct-conversations", params={"peer_user_id": "bob"})
        assert unauthenticated.status_code == 401
        self_query = await client.get(
            "/api/v1/direct-conversations",
            params={"peer_user_id": "alice"},
            headers={"Authorization": f"Bearer {_token(factory, 'alice')}"})
        assert self_query.status_code == 422
