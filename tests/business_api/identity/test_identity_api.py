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
from app.modules.identity.passwords import PasswordHasher


@pytest.fixture()
def api_components():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    InvitationService(factory).issue(
        code="API-INVITE",
        max_uses=2,
        expires_at=now + timedelta(days=1),
        created_by="admin-1",
    )
    with factory.begin() as session:
        session.add(
            User(
                id="active-user",
                username="active",
                username_normalized="active",
                email="active@example.com",
                email_normalized="active@example.com",
                password_hash=PasswordHasher().hash("correct horse battery staple"),
                status=AccountStatus.ACTIVE,
                matrix_user_id="@active:matrix.localhost",
                email_verified_at=now,
                created_at=now,
                updated_at=now,
            )
        )
    settings = Settings(
        _env_file=None,
        environment="test",
        database_url="sqlite+pysqlite:///:memory:",
        redis_url="redis://localhost:6379/15",
        jwt_secret="test-jwt-secret-at-least-thirty-two-bytes",
        email_verification_secret="test-email-verification-secret",
        password_reset_secret="test-password-reset-secret",
    )
    yield create_app(settings, session_factory=factory), factory
    engine.dispose()


@pytest.mark.asyncio
async def test_registration_requires_invitation_and_rejects_phone(api_components) -> None:
    app, _ = api_components
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        valid = await client.post(
            "/api/v1/auth/register",
            headers={"Idempotency-Key": "identity-api-valid"},
            json={
                "username": "alice",
                "email": "alice@example.com",
                "password": "correct horse battery staple",
                "invitation_code": "API-INVITE",
            },
        )
        invalid = await client.post(
            "/api/v1/auth/register",
            headers={"Idempotency-Key": "identity-api-invalid"},
            json={
                "username": "bob",
                "email": "bob@example.com",
                "password": "correct horse battery staple",
                "invitation_code": "API-INVITE",
                "phone": "+85200000000",
            },
        )

    assert valid.status_code == 202
    assert valid.json()["status"] == "PENDING_EMAIL"
    assert "registration_session" in valid.json()
    assert "user_id" not in valid.json()
    assert "verification_token" not in valid.json()
    assert invalid.status_code == 422


@pytest.mark.asyncio
async def test_login_refresh_devices_and_logout(api_components) -> None:
    app, _ = api_components
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        login = await client.post(
            "/api/v1/auth/login",
            json={
                "username": "active",
                "password": "correct horse battery staple",
                "device_key": "device-1",
                "device_name": "Test Phone",
            },
        )
        assert login.status_code == 200
        tokens = login.json()
        headers = {"Authorization": f"Bearer {tokens['access_token']}"}
        devices = await client.get("/api/v1/devices", headers=headers)
        refreshed = await client.post(
            "/api/v1/auth/refresh", json={"refresh_token": tokens["refresh_token"]}
        )
        logout = await client.post(
            "/api/v1/auth/logout",
            json={"refresh_token": refreshed.json()["refresh_token"]},
        )

    assert devices.status_code == 200
    assert devices.json()[0]["display_name"] == "Test Phone"
    assert refreshed.status_code == 200
    assert logout.status_code == 204


@pytest.mark.asyncio
async def test_forgot_password_has_generic_response(api_components) -> None:
    app, _ = api_components
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        known = await client.post(
            "/api/v1/auth/password/forgot", json={"email": "active@example.com"}
        )
        unknown = await client.post(
            "/api/v1/auth/password/forgot", json={"email": "missing@example.com"}
        )

    assert known.status_code == unknown.status_code == 202
    assert known.json() == unknown.json()
