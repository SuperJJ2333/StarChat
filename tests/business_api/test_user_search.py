"""添加朋友搜索：畅聊号与完整邮箱精确匹配、阈值、排序与脱敏。"""
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
from app.modules.identity.models import Device, User, UserRole


@pytest.fixture()
def context():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)

    def add_user(user_id, username, email, nickname, seen_minutes_ago=None):
        with factory.begin() as session:
            session.add(User(
                id=user_id,
                username=username,
                username_normalized=username.casefold(),
                email=email,
                email_normalized=email.casefold(),
                password_hash="x",
                nickname=nickname,
                status=AccountStatus.ACTIVE,
                created_at=now,
                updated_at=now,
            ))
            if seen_minutes_ago is not None:
                session.add(Device(
                    id=f"dev-{user_id}",
                    user_id=user_id,
                    device_key="d1",
                    display_name="phone",
                    last_seen_at=now - timedelta(minutes=seen_minutes_ago),
                    created_at=now,
                ))

    add_user("me-1", " seeker", "seeker@example.com", "我自己")
    add_user("u-al", "alice", "alice@example.com", "艾莉丝", seen_minutes_ago=5)
    add_user("u-al2", "alina", "alina@test.org", "艾琳娜", seen_minutes_ago=1)
    add_user("u-x", "xalice", "xalice@example.com", "中缀不应命中", seen_minutes_ago=0)
    add_user("u-em", "tom2000", "alice.fan@example.com", "邮箱前缀命中", seen_minutes_ago=2)
    with factory.begin() as session:
        session.add(UserRole(id="r1", user_id="me-1", role_code=RoleCode.SUPER_ADMIN, assigned_by="bootstrap", assigned_at=now))
    settings = Settings(_env_file=None, environment="test", database_url="sqlite+pysqlite:///:memory:", redis_url="redis://localhost:6379/15", jwt_secret="r" * 32, totp_issuer="六合通")
    app = create_app(settings, session_factory=factory)
    yield app, factory, settings
    engine.dispose()


def bearer(settings, user_id):
    now = datetime.now(timezone.utc)
    value = jwt.encode({"sub": user_id, "iss": settings.jwt_issuer, "iat": int(now.timestamp()), "exp": int((now + timedelta(minutes=5)).timestamp())}, settings.jwt_secret, algorithm="HS256")
    return {"Authorization": f"Bearer {value}"}


def search_ids(body):
    return [item["user_id"] for item in body["items"]]


@pytest.mark.asyncio
async def test_single_character_query_is_rejected(context):
    app, _factory, settings = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/api/v1/users/search", params={"q": "a"}, headers=bearer(settings, "me-1"))
    assert response.status_code == 422


@pytest.mark.asyncio
async def test_chat_id_query_excludes_email_prefix_and_infix(context):
    app, _factory, settings = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/api/v1/users/search", params={"q": "alice"}, headers=bearer(settings, "me-1"))
    assert response.status_code == 200
    ids = search_ids(response.json())
    # 当前畅聊号发现规则命中 alice/alina；不把邮箱前缀或中缀当作结果。
    assert "u-al" in ids
    assert "u-al2" in ids
    assert "u-em" not in ids
    assert "u-x" not in ids


@pytest.mark.asyncio
async def test_full_email_search_is_case_insensitive_and_prefix_is_rejected(context):
    app, _factory, settings = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/api/v1/users/search", params={"q": "ALICE.FAN@EXAMPLE.COM"}, headers=bearer(settings, "me-1"))
        prefix = await client.get("/api/v1/users/search", params={"q": "ALICE.FAN@EXAMPLE"}, headers=bearer(settings, "me-1"))
    assert response.status_code == 200
    assert search_ids(response.json()) == ["u-em"]
    assert prefix.status_code == 200
    assert search_ids(prefix.json()) == []


@pytest.mark.asyncio
async def test_chat_id_hits_rank_by_recent_activity_without_email_fallback(context):
    app, _factory, settings = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/api/v1/users/search", params={"q": "ali"}, headers=bearer(settings, "me-1"))
    ids = search_ids(response.json())
    # 畅聊号命中按最近活跃倒序：alina 1 分钟前 > alice 5 分钟前；
    # 没有 @ 的检索不能回退到 alice.fan 的邮箱前缀。
    assert ids == ["u-al2", "u-al"]


@pytest.mark.asyncio
async def test_results_exclude_self_and_carry_no_email(context):
    app, _factory, settings = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/api/v1/users/search", params={"q": "seeker"}, headers=bearer(settings, "me-1"))
        sample = await client.get("/api/v1/users/search", params={"q": "alice"}, headers=bearer(settings, "me-1"))
    assert response.json()["items"] == []
    for item in sample.json()["items"]:
        assert "email" not in item
        assert set(item) == {"user_id", "username", "nickname", "avatar_url", "matrix_user_id", "relationship_state"}


@pytest.mark.asyncio
async def test_search_requires_authentication(context):
    app, _factory, _settings = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/api/v1/users/search", params={"q": "alice"})
    assert response.status_code == 401
