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

        friends = await client.get("/api/v1/friends", headers=bearer(settings, "u-admin"))
        items = friends.json()["items"]
        mine = next(item for item in items if item["user_id"] == "u-bob")
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


@pytest.mark.asyncio
async def test_outgoing_acceptance_projects_target_and_original_greeting(context):
    app, factory, settings = context
    with factory.begin() as session:
        session.get(User, "u-bob").matrix_user_id = "@bob:matrix.example.test"
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        created = await send(client, settings, "u-admin", "我是申请人", "outgoing-1")
        request_id = created.json()["id"]
        # Listing an outgoing request never grants its requester accept/reject authority.
        forbidden = await client.post(f"/api/v1/friends/requests/{request_id}/accept", headers={**bearer(settings, "u-admin"), "Idempotency-Key": "self-accept"})
        assert forbidden.status_code == 404
        accepted = await client.post(f"/api/v1/friends/requests/{request_id}/accept", headers={**bearer(settings, "u-bob"), "Idempotency-Key": "outgoing-accept"})
        assert accepted.status_code == 200
        response = await client.get("/api/v1/friends/requests", headers=bearer(settings, "u-admin"))
        assert response.status_code == 200
        assert len(response.json()["items"]) == 1
        item = response.json()["items"][0]
        assert item["direction"] == "OUTGOING"
        assert item["id"] == request_id
        assert item["status"] == "ACCEPTED"
        assert item["message"] == "我是申请人"
        assert item["user_id"] == "u-bob"
        assert item["matrix_user_id"] == "@bob:matrix.example.test"
        assert item["username"] == "bob"
        incoming = (await pending_items(client, settings))[0]
        assert incoming["direction"] == "INCOMING"
        assert incoming["user_id"] == "u-admin"
        unrelated = await client.get("/api/v1/friends/requests", headers=bearer(settings, "u-unrelated"))
        assert unrelated.json()["items"] == []


@pytest.mark.asyncio
async def test_hide_both_request_preferences_belong_only_to_requester(context):
    app, _factory, settings = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        created = await send(client, settings, "u-admin", "你好", "both-1", moments_permission="HIDE_BOTH")
        assert created.status_code == 201
        accepted = await client.post(f"/api/v1/friends/requests/{created.json()['id']}/accept", headers={**bearer(settings, "u-bob"), "Idempotency-Key": "both-accept"})
        assert accepted.status_code == 200
        sender = await client.get("/api/v1/friends", headers=bearer(settings, "u-admin"))
        receiver = await client.get("/api/v1/friends", headers=bearer(settings, "u-bob"))
        assert sender.json()["items"][0]["moments_permission"] == "HIDE_BOTH"
        assert receiver.json()["items"][0]["moments_permission"] == "DEFAULT"
        patched = await client.patch("/api/v1/friends/u-admin", headers={**bearer(settings, "u-bob"), "Idempotency-Key": "both-patch"}, json={"moments_permission": "HIDE_BOTH"})
        assert patched.status_code == 200
        assert patched.json()["moments_permission"] == "HIDE_BOTH"


@pytest.mark.parametrize("owner,permission,expected", [
    ("u-admin", "HIDE_MINE", False),
    ("u-admin", "HIDE_THEIRS", True),
    ("u-admin", "HIDE_BOTH", False),
    ("u-admin", "CHAT_ONLY", False),
    ("u-admin", "ONLY_CHAT", False),
    ("u-bob", "HIDE_THEIRS", False),
    ("u-bob", "HIDE_MINE", True),
    ("u-bob", "HIDE_BOTH", False),
    ("u-bob", "CHAT_ONLY", False),
    ("u-bob", "ONLY_CHAT", False),
    ("u-admin", "DEFAULT", True),
])
def test_moments_respects_directional_contact_permissions(context, owner, permission, expected):
    from types import SimpleNamespace
    from app.modules.friendship.models import ContactProfile, Friendship
    from app.modules.moments.visibility import VisibilityPolicy

    _app, factory, _settings = context
    with factory.begin() as session:
        session.add(Friendship(id="f1", user_low_id="u-admin", user_high_id="u-bob", created_at=datetime.now(timezone.utc)))
        session.add(ContactProfile(id="cp1", owner_id=owner, contact_id="u-bob" if owner == "u-admin" else "u-admin", moments_permission=permission))
    with factory() as session:
        policy = VisibilityPolicy(session)
        for visibility in ("PUBLIC", "FRIENDS", "INCLUDE", "EXCLUDE"):
            moment = SimpleNamespace(author_id="u-admin", visibility=visibility, include_user_ids=["u-bob"], exclude_user_ids=[])
            assert policy.can_view("u-bob", moment) is expected
            assert policy.can_view("u-admin", moment) is True


@pytest.mark.asyncio
@pytest.mark.parametrize("resolved", [False, True])
async def test_private_request_preferences_are_visible_only_to_requester(context, resolved):
    app, _factory, settings = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        created = await send(client, settings, "u-admin", "公开打招呼", "private-request", remark="私人备注", tags=["私人标签"])
        assert created.status_code == 201
        if resolved:
            response = await client.post(f"/api/v1/friends/requests/{created.json()['id']}/accept", headers={**bearer(settings, "u-bob"), "Idempotency-Key": "private-accept"})
            assert response.status_code == 200
        outgoing = await client.get("/api/v1/friends/requests", headers=bearer(settings, "u-admin"))
        assert outgoing.json()["items"][0]["remark"] == "私人备注"
        assert outgoing.json()["items"][0]["tags"] == ["私人标签"]
        incoming = (await pending_items(client, settings))[0]
        assert incoming["message"] == "公开打招呼"
        assert incoming["remark"] is None
        assert incoming["tags"] == []
        unrelated = await client.get("/api/v1/friends/requests", headers=bearer(settings, "u-unrelated"))
        assert unrelated.json()["items"] == []
        for actor in ("u-bob", "u-unrelated"):
            friends = await client.get("/api/v1/friends", headers=bearer(settings, actor))
            for friend in friends.json()["items"]:
                assert friend["remark"] is None
                assert friend["tags"] == []
            tags = await client.get("/api/v1/contact-tags", headers=bearer(settings, actor))
            assert tags.json()["items"] == []
