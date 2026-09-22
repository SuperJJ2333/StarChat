"""Phone registration must traverse the real provisioning and profile services."""
from types import SimpleNamespace

import pytest
from sqlalchemy import select

from app.core.errors import AppError
from app.core.outbox import OutboxEvent
from app.integrations.matrix_admin import MatrixCredentialCodec
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User
from app.modules.identity.profile import ProfileService
from app.modules.identity.provisioning import MatrixProvisionTask
from app.modules.admin.service import AdminControlService
from test_phone_auth import env, _register_phone


def _phone_event(env):
    factory, _, _, auth, sender, _, _ = env
    registered = _register_phone(env)
    auth.request_registration_otp(registration_session=registered.registration_session)
    auth.verify_registration(registration_session=registered.registration_session,
        phone="13800000001", code=sender.messages[-1][1])
    with factory() as session:
        event = session.scalar(select(OutboxEvent).where(
            OutboxEvent.event_type == "identity.matrix.provision.requested"))
    return registered, event


@pytest.mark.asyncio
async def test_verified_phone_provisions_matrix_then_logs_in_and_reads_profile(env):
    from fastapi import FastAPI
    from httpx import ASGITransport, AsyncClient
    from app.api.profile import create_profile_router
    from app.core.config import Settings
    from app.modules.identity.tokens import TokenService

    factory, _, _, auth, sender, clock, _ = env
    registered, event = _phone_event(env)
    calls = []
    def ensure_user(localpart, password):
        calls.append(localpart)
        return f"@{localpart}:matrix.example.test"
    task = MatrixProvisionTask(factory, gateway=SimpleNamespace(ensure_user=ensure_user),
        credential_codec=MatrixCredentialCodec(b"test-matrix-provision-secret"), now_factory=clock)
    task(event)
    task(event)
    assert calls == ["alice"]
    with factory() as session:
        user = session.get(User, registered.user_id)
        assert user.status == AccountStatus.ACTIVE
        assert user.email is None and user.email_verified_at is None
        assert user.phone_verified_at is not None
    settings = Settings(_env_file=None, environment="test", database_url="sqlite+pysqlite:///:memory:",
        redis_url="redis://localhost:6379/15", jwt_secret="test-jwt-secret-at-least-thirty-two-bytes")
    tokens = TokenService(factory, jwt_secret=settings.jwt_secret, jwt_issuer=settings.jwt_issuer)
    auth.request_login_otp(phone="13800000001")
    pair = auth.login(phone="13800000001", code=sender.messages[-1][1], tokens=tokens,
        device_key="phone-provisioned-device", device_name="Phone")
    app = FastAPI()
    app.include_router(create_profile_router(settings, factory, storage=SimpleNamespace()), prefix="/api/v1")
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/api/v1/profile/me", headers={"Authorization": "Bearer " + pair.access_token})
    assert response.status_code == 200, response.text
    assert response.json()["username"] == "alice"
    assert response.json()["masked_email"] == ""
    assert "13800000001" not in response.text


def test_phone_profile_without_email_keeps_string_response_contract(env):
    factory, _, _, _, _, clock, _ = env
    registered = _register_phone(env)
    assert ProfileService(factory, storage=SimpleNamespace(), now_factory=clock).get(registered.user_id).masked_email == ""


def test_phone_only_support_agent_list_has_empty_masked_email(env):
    from uuid import uuid4
    from app.modules.identity.enums import RoleCode
    from app.modules.identity.models import UserRole

    factory, _, _, _, _, clock, _ = env
    registered = _register_phone(env)
    with factory.begin() as session:
        session.add(UserRole(id=str(uuid4()), user_id=registered.user_id,
            role_code=RoleCode.SUPPORT_AGENT, assigned_by="test-admin", assigned_at=clock()))
    result = AdminControlService(factory, now_factory=clock).support_agents(query=None,
        limit=20, offset=0, dispatch_eligible=True)
    assert result["items"][0]["masked_email"] == ""


@pytest.mark.parametrize("mutation", ["unverified", "missing_phone", "revoked_during_provision"])
def test_provisioning_requires_verified_existing_phone_at_activation(env, mutation):
    factory, _, _, _, _, clock, _ = env
    registered, event = _phone_event(env)
    if mutation != "revoked_during_provision":
        with factory.begin() as session:
            user = session.get(User, registered.user_id)
            if mutation == "unverified":
                user.phone_verified_at = None
            else:
                user.phone_normalized = None
    def ensure_user(localpart, password):
        with factory.begin() as session:
            session.get(User, registered.user_id).phone_verified_at = None
        return f"@{localpart}:matrix.example.test"
    task = MatrixProvisionTask(factory, gateway=SimpleNamespace(ensure_user=ensure_user),
        credential_codec=MatrixCredentialCodec(b"test-matrix-provision-secret"), now_factory=clock)
    with pytest.raises(AppError):
        task(event)
    with factory() as session:
        assert session.get(User, registered.user_id).status == AccountStatus.PENDING_MATRIX
