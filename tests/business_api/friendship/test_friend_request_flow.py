"""好友申请：去重更新 / 已处理后再申请新建记录 / 接受时应用备注标签权限。"""
from datetime import datetime, timedelta, timezone

import jwt
import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.main import create_app
from app.modules.identity.enums import AccountStatus, RoleCode
from app.modules.identity.models import User, UserRole


@pytest.fixture()
def context():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(User(id="u-admin", username="admin", username_normalized="admin", email="a@x.com", email_normalized="a@x.com", password_hash="x", nickname="管理员", status=AccountStatus.ACTIVE, created_at=now, updated_at=now))
        session.add(User(id="u-bob", username="bob", username_normalized="bob", email="b@x.com", email_normalized="b@x.com", password_hash="x", nickname="波仔", status=AccountStatus.ACTIVE, created_at=now, updated_at=now))
        session.add(UserRole(id="r1", user_id="u-admin", role_code=RoleCode.SUPER_ADMIN, assigned_by="bootstrap", assigned_at=now))
    settings = Settings(_env_file=None, environment="test", database_url="sqlite+pysqlite:///:memory:", redis_url="redis://localhost:6379/15", jwt_secret="r" * 32, totp_issuer="六合通")
    app = create_app(settings, session_factory=factory)
    yield app, factory, settings
    engine.dispose()


def bearer(settings, user_id):
    now = datetime.now(timezone.utc)
    value = jwt.encode({"sub": user_id, "iss": settings.jwt_issuer, "iat": int(now.timestamp()), "exp": int((now + timedelta(minutes=5)).timestamp())}, settings.jwt_secret, algorithm="HS256")
    return {"Authorization": f"Bearer {value}"}


def send(client, settings, requester, message, idem, **extra):
    return client.post(
        "/api/v1/friends/requests",
        headers={**bearer(settings, requester), "Idempotency-Key": idem},
        json={"target_user_id": "u-bob", "message": message, **extra},
    )


async def pending_items(client, settings):
    response = await client.get("/api/v1/friends/requests", headers=bearer(settings, "u-bob"))
    assert response.status_code == 200
    return response.json()["items"]


@pytest.mark.asyncio
async def test_repeat_pending_request_updates_in_place_without_new_record(context):
    app, _factory, settings = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        first = await send(client, settings, "u-admin", "第一次打招呼", "idem-1", remark="老王", tags=["同事"], moments_permission="HIDE_MINE")
        assert first.status_code == 201
        assert first.json()["duplicate"] is False

        second = await send(client, settings, "u-admin", "第二次打招呼", "idem-2", remark="老王二号", tags=["同事", "球友"], moments_permission="CHAT_ONLY")
        assert second.status_code == 201
        assert second.json()["duplicate"] is True
        assert second.json()["id"] == first.json()["id"]

        items = await pending_items(client, settings)
        assert len(items) == 1, "重复申请不得新增展示记录"
        assert items[0]["message"] == "第二次打招呼"


@pytest.mark.asyncio
async def test_request_after_reject_creates_a_fresh_record(context):
    app, _factory, settings = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        first = await send(client, settings, "u-admin", "第一次", "idem-r1")
        request_id = first.json()["id"]
        rejected = await client.post(f"/api/v1/friends/requests/{request_id}/reject", headers={**bearer(settings, "u-bob"), "Idempotency-Key": "rej-1"})
        assert rejected.status_code == 200

        again = await send(client, settings, "u-admin", "重新申请", "idem-r2")
        assert again.status_code == 201
        assert again.json()["duplicate"] is False
        assert again.json()["id"] != request_id

        items = await pending_items(client, settings)
        pending = [item for item in items if item["status"] == "PENDING"]
        assert len(pending) == 1 and pending[0]["message"] == "重新申请"


@pytest.mark.asyncio
async def test_accept_applies_requester_contact_preferences(context):
    app, factory, settings = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        first = await send(
            client, settings, "u-admin", "加个好友呗", "idem-a1",
            remark="项目老王", tags=["同事", "球友"], moments_permission="CHAT_ONLY",
        )
        request_id = first.json()["id"]
        accepted = await client.post(f"/api/v1/friends/requests/{request_id}/accept", headers={**bearer(settings, "u-bob"), "Idempotency-Key": "acc-1"})
        assert accepted.status_code == 200

        friends = await client.get("/api/v1/friends", headers=bearer(settings, "u-bob"))
        items = friends.json()["items"]
        mine = next(item for item in items if item["user_id"] == "u-admin")
        assert mine["remark"] == "项目老王"
        assert mine["tags"] == ["同事", "球友"]
        assert mine["moments_permission"] == "CHAT_ONLY"


@pytest.mark.asyncio
async def test_friends_cannot_request_again(context):
    app, _factory, settings = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        first = await send(client, settings, "u-admin", "交个朋友", "idem-f1")
        request_id = first.json()["id"]
        await client.post(f"/api/v1/friends/requests/{request_id}/accept", headers={**bearer(settings, "u-bob"), "Idempotency-Key": "acc-f1"})

        blocked = await send(client, settings, "u-admin", "又来", "idem-f2")
        assert blocked.status_code == 409
        assert blocked.json()["error"]["code"] == "FRIEND_REQUEST_DUPLICATE"
