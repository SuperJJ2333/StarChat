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
        session.add(User(id="admin-1", username="admin", username_normalized="admin", email="a@x.com", email_normalized="a@x.com", password_hash="x", status=AccountStatus.ACTIVE, created_at=now, updated_at=now))
        session.add(UserRole(id="r1", user_id="admin-1", role_code=RoleCode.SUPER_ADMIN, assigned_by="bootstrap", assigned_at=now))
        session.add(User(id="member-1", username="member", username_normalized="member", email="m@x.com", email_normalized="m@x.com", password_hash="x", status=AccountStatus.ACTIVE, created_at=now, updated_at=now))
    settings = Settings(_env_file=None, environment="test", database_url="sqlite+pysqlite:///:memory:", redis_url="redis://localhost:6379/15", jwt_secret="r" * 32, totp_issuer="六合通")
    app = create_app(settings, session_factory=factory)
    yield app, factory, settings
    engine.dispose()


def bearer(settings, user_id):
    now = datetime.now(timezone.utc)
    value = jwt.encode({"sub": user_id, "iss": settings.jwt_issuer, "iat": int(now.timestamp()), "exp": int((now + timedelta(minutes=5)).timestamp())}, settings.jwt_secret, algorithm="HS256")
    return {"Authorization": f"Bearer {value}"}


PAYLOAD = {
    "latest_version": "0.4.0",
    "latest_build": 4,
    "min_supported_build": 2,
    "notes": "修复已知问题，新增版本更新提醒。",
    "apk_url": "https://www.liuhetong888.com/downloads/app-release.apk",
}


@pytest.mark.asyncio
async def test_latest_requires_authentication(context):
    app, _factory, _settings = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/api/v1/app-updates/latest")
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "AUTH_REQUIRED"


@pytest.mark.asyncio
async def test_latest_is_unconfigured_by_default(context):
    app, _factory, settings = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/api/v1/app-updates/latest", headers=bearer(settings, "member-1"))
    assert response.status_code == 200
    body = response.json()
    assert body["configured"] is False
    assert body["latest_build"] is None


@pytest.mark.asyncio
async def test_non_admin_cannot_update_settings(context):
    app, _factory, settings = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        denied = await client.put("/api/v1/admin/app-update-settings", headers={**bearer(settings, "member-1"), "Idempotency-Key": "upd-1"}, json=PAYLOAD)
        assert denied.status_code == 403
        forbidden_read = await client.get("/api/v1/admin/app-update-settings", headers=bearer(settings, "member-1"))
        assert forbidden_read.status_code == 403


@pytest.mark.asyncio
async def test_admin_publishes_and_client_reads_update(context):
    app, _factory, settings = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        updated = await client.put("/api/v1/admin/app-update-settings", headers={**bearer(settings, "admin-1"), "Idempotency-Key": "upd-1"}, json=PAYLOAD)
        assert updated.status_code == 200
        assert updated.json()["latest_build"] == 4

        stored = await client.get("/api/v1/admin/app-update-settings", headers=bearer(settings, "admin-1"))
        assert stored.status_code == 200
        assert stored.json()["latest_version"] == "0.4.0"
        assert stored.json()["min_supported_build"] == 2

        latest = await client.get("/api/v1/app-updates/latest", headers=bearer(settings, "member-1"))
        assert latest.status_code == 200
        body = latest.json()
        assert body["configured"] is True
        assert body["latest_build"] == 4
        assert body["min_supported_build"] == 2
        assert body["apk_url"].endswith("/downloads/app-release.apk")
        assert body["notes"]


@pytest.mark.asyncio
async def test_min_supported_build_cannot_exceed_latest(context):
    app, _factory, settings = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        rejected = await client.put(
            "/api/v1/admin/app-update-settings",
            headers={**bearer(settings, "admin-1"), "Idempotency-Key": "upd-2"},
            json={**PAYLOAD, "min_supported_build": 99},
        )
    assert rejected.status_code == 422
    assert rejected.json()["error"]["code"] == "APP_UPDATE_SETTING_INVALID"
