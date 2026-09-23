"""Security regression cases from the independent phone-auth review."""
import pytest
from sqlalchemy import select

from app.core.errors import AppError
from app.core.outbox import OutboxEvent
from app.modules.identity.models import OtpChallenge
import app.modules.audit.models  # noqa: F401
from test_phone_auth import env, _register_phone, _activate


def test_wrong_attempts_commit_and_lock_challenge(env):
    factory, _, otp, _, sender, _, _ = env
    result = _register_phone(env)
    otp.issue(purpose="login", phone="+8613800000001", user_id=result.user_id)
    correct = sender.messages[-1][1]
    wrong = "000000" if correct != "000000" else "111111"
    for _ in range(5):
        with pytest.raises(AppError):
            otp.verify_code(purpose="login", target="+8613800000001", code=wrong, user_id=result.user_id)
    with factory() as session:
        assert session.scalar(select(OtpChallenge)).attempts_left == 0
    with pytest.raises(AppError):
        otp.verify_code(purpose="login", target="+8613800000001", code=correct, user_id=result.user_id)


def test_completed_rebind_cannot_authorize_another_rebind(env):
    factory, _, otp, auth, sender, _, _ = env
    result = _register_phone(env)
    _activate(factory, result.user_id)
    auth.request_old_channel_verification(user_id=result.user_id)
    otp.verify_code(purpose="phone_rebind_old", target="+8613800000001", code=sender.messages[-1][1], user_id=result.user_id)
    auth.request_new_phone_verification(user_id=result.user_id, new_phone="+8613900000002")
    auth.confirm_new_phone(user_id=result.user_id, new_phone="+8613900000002", code=sender.messages[-1][1])
    with pytest.raises(AppError):
        auth.request_new_phone_verification(user_id=result.user_id, new_phone="+8613500000003")


def test_rebind_grant_expires_after_five_minutes(env):
    factory, _, otp, auth, sender, clock, _ = env
    result = _register_phone(env)
    _activate(factory, result.user_id)
    auth.request_old_channel_verification(user_id=result.user_id)
    otp.verify_code(purpose="phone_rebind_old", target="+8613800000001", code=sender.messages[-1][1], user_id=result.user_id)
    clock.advance(minutes=6)
    with pytest.raises(AppError):
        auth.request_new_phone_verification(user_id=result.user_id, new_phone="+8613900000002")


def test_phone_registration_replay_returns_original_result(env):
    first = _register_phone(env)
    replay = _register_phone(env)
    assert replay.user_id == first.user_id
    assert replay.registration_session == first.registration_session


def test_registration_rejects_two_channels(env):
    _, registration, _, _, _, _, _ = env
    with pytest.raises(AppError):
        registration.register(username="bothchannels", email="both@example.com", phone="+8613800000001",
            password="correct horse battery staple", invitation_code="WELCOME-1", idempotency_key="both")


def test_email_rebind_outbox_does_not_persist_plaintext_code(env):
    factory, registration, _, auth, _, _, _ = env
    result = registration.register(username="emailuser", email="user@example.com", password="correct horse battery staple",
        invitation_code="WELCOME-1", idempotency_key="email-reg")
    _activate(factory, result.user_id)
    auth.request_old_channel_verification(user_id=result.user_id)
    with factory() as session:
        event = session.scalar(select(OutboxEvent).where(OutboxEvent.event_type == "identity.email.otp.requested"))
        assert set(event.payload) == {"otp_id"}


@pytest.mark.asyncio
async def test_public_phone_flow_registration_login_rebind_and_privacy(env):
    from fastapi import FastAPI
    from httpx import ASGITransport, AsyncClient
    from app.api.identity import create_identity_router
    from app.core.config import Settings
    from app.core.errors import install_error_handlers
    from app.modules.identity.enums import AccountStatus
    from app.modules.identity.models import User

    factory, _, _, _, sender, _, _ = env
    # The HTTP router uses the wall clock; do not reuse the service fixture's
    # fixed 2026-09-21 invitation, which expires while this test remains valid.
    from datetime import datetime, timedelta, timezone
    from app.modules.identity.invitations import InvitationService
    InvitationService(factory).issue(code="API-WELCOME", max_uses=10,
        expires_at=datetime.now(timezone.utc) + timedelta(days=1), created_by="admin")
    class Limiter:
        def hit(self, *args, **kwargs):
            pass
    settings = Settings(_env_file=None, environment="test", phone_auth_enabled=True,
        database_url="sqlite+pysqlite:///:memory:", redis_url="redis://localhost:6379/15",
        jwt_secret="test-jwt-secret-at-least-thirty-two-bytes",
        email_verification_secret="test-email-verification-secret", password_reset_secret="test-password-reset-secret")
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(create_identity_router(settings, factory, Limiter(), matrix_gateway=None, sms_sender=sender), prefix="/api/v1")
    client = AsyncClient(transport=ASGITransport(app=app), base_url="http://test")
    base = "/api/v1"
    registered = await client.post(base + "/auth/register", headers={"Idempotency-Key": "api-phone"}, json={
        "username": "phoneapi", "phone": "13800000001", "password": "correct horse battery staple", "invitation_code": "API-WELCOME"})
    assert registered.status_code == 202, registered.text
    registration_session = registered.json()["registration_session"]
    requested = await client.post(base + "/auth/phone/registration/request", json={"registration_session": registration_session})
    assert requested.status_code == 202, requested.text
    verified = await client.post(base + "/auth/phone/registration/verify", json={"registration_session": registration_session,
        "phone": "13800000001", "code": sender.messages[-1][1]})
    assert verified.status_code == 202, verified.text
    assert (await client.get(base + "/auth/registrations/" + registration_session)).json()["status"] == "PENDING_MATRIX"
    with factory.begin() as session:
        user = session.scalar(select(User).where(User.username == "phoneapi"))
        user_id = user.id
        user.status = AccountStatus.ACTIVE
        user.matrix_user_id = "@phoneapi:test"
    assert (await client.post(base + "/auth/phone/login/request", json={"phone": "13800000001"})).status_code == 202
    logged_in = await client.post(base + "/auth/phone/login", json={"phone": "13800000001", "code": sender.messages[-1][1],
        "device_key": "device-api-phone", "device_name": "test phone"})
    assert logged_in.status_code == 200, logged_in.text
    headers = {"Authorization": "Bearer " + logged_in.json()["access_token"]}
    assert logged_in.json()["matrix_user_id"] == "@phoneapi:test"
    assert (await client.post(base + "/auth/phone/rebind/old-request", headers=headers)).status_code == 202
    assert (await client.post(base + "/auth/phone/rebind/old-confirm", headers=headers, json={"code": sender.messages[-1][1]})).status_code == 200
    assert (await client.post(base + "/auth/phone/rebind/new-request", headers=headers, json={"phone": "13900000002"})).status_code == 202
    confirmed = await client.post(base + "/auth/phone/rebind/confirm", headers=headers,
        json={"new_phone": "13900000002", "code": sender.messages[-1][1]})
    assert confirmed.status_code == 200, confirmed.text
    assert (await client.patch(base + "/auth/phone/privacy", headers=headers, json={"phone_findable": False})).status_code == 200
    assert (await client.post(base + "/contacts/search-phone", headers=headers, json={"phone": "13900000002"})).json() == {"found": False}

    await client.aclose()


@pytest.mark.parametrize("state", ["valid", "expired", "changed_email", "phone_bound", "invalidated"])
def test_email_otp_worker_derivation_and_stale_delivery_guard(env, state):
    from types import SimpleNamespace
    from app.modules.identity.models import User
    from app.modules.identity.registration import VerificationTokenCodec
    from tasks.identity import IdentityEmailVerificationTask

    factory, registration, otp, auth, _, clock, _ = env
    codec = VerificationTokenCodec(b"test-email-verification-secret")
    auth._email_code_deriver = codec.verification_code
    result = registration.register(username="emailworker", email="worker@example.com", password="correct horse battery staple",
        invitation_code="WELCOME-1", idempotency_key="worker-reg")
    _activate(factory, result.user_id)
    auth.request_old_channel_verification(user_id=result.user_id)
    with factory.begin() as session:
        event = session.scalar(select(OutboxEvent).where(OutboxEvent.event_type == "identity.email.otp.requested"))
        challenge = session.get(OtpChallenge, event.aggregate_id)
        user = session.get(User, result.user_id)
        if state == "expired":
            clock.advance(minutes=6)
        elif state == "changed_email":
            user.email_normalized = "changed@example.com"
        elif state == "phone_bound":
            user.phone_normalized = "+8613800000001"
        elif state == "invalidated":
            challenge.invalidated_at = clock()
    delivered = []
    sender = SimpleNamespace(send_email_otp=lambda **message: delivered.append(message))
    task = IdentityEmailVerificationTask(factory, token_codec=codec, public_base_url="https://example.test",
        email_sender=sender, now_factory=clock)
    task(SimpleNamespace(event_type=event.event_type, payload=event.payload, aggregate_id=event.aggregate_id))
    if state == "valid":
        assert len(delivered) == 1
        otp.verify_code(purpose="email_rebind_old", target="worker@example.com", user_id=result.user_id,
            code=delivered[0]["code"])
    else:
        assert delivered == []
