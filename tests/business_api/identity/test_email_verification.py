from __future__ import annotations

from datetime import datetime, timedelta, timezone

from httpx import ASGITransport, AsyncClient
import pytest
from sqlalchemy import create_engine, func, select

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.core.outbox import OutboxEvent
from app.main import create_app
from app.modules.identity.enums import AccountStatus
from app.modules.identity.invitations import InvitationService
from app.modules.identity.models import EmailVerificationChallenge, User
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.registration import (
    EmailVerificationService,
    RegistrationService,
    VerificationTokenCodec,
)


@pytest.fixture()
def verification_components():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False})
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    clock = {"now": datetime(2026, 8, 14, 8, 0, tzinfo=timezone.utc)}

    def now_factory():
        return clock["now"]

    invitations = InvitationService(factory, now_factory=now_factory)
    codec = VerificationTokenCodec(b"test-email-verification-secret")
    registration = RegistrationService(
        factory,
        invitation_service=invitations,
        password_hasher=PasswordHasher(),
        token_codec=codec,
        now_factory=now_factory,
    )
    verification = EmailVerificationService(
        factory,
        token_codec=codec,
        now_factory=now_factory,
    )
    yield factory, clock, invitations, codec, registration, verification
    engine.dispose()


def _register(components, suffix: str):
    _, clock, invitations, _, registration, _ = components
    invitation_code = f"VERIFY-{suffix}"
    invitations.issue(
        code=invitation_code,
        max_uses=1,
        expires_at=clock["now"] + timedelta(days=1),
        created_by="admin-1",
    )
    return registration.register(
        username=f"user-{suffix}",
        email=f"user-{suffix}@example.com",
        password="correct horse battery staple",
        invitation_code=invitation_code,
        idempotency_key=f"registration-{suffix}",
    )


def _challenge(factory, user_id: str) -> EmailVerificationChallenge:
    with factory() as session:
        return session.scalar(
            select(EmailVerificationChallenge).where(
                EmailVerificationChallenge.user_id == user_id,
                EmailVerificationChallenge.invalidated_at.is_(None),
            )
        )


def test_six_digit_code_verifies_once_without_storing_plaintext(
    verification_components,
) -> None:
    factory, _, _, codec, _, verification = verification_components
    registration = _register(verification_components, "code")
    challenge = _challenge(factory, registration.user_id)
    code = codec.verification_code(challenge.id)

    first = verification.verify(
        registration_session=registration.registration_session,
        code=code,
        token=None,
        idempotency_key="verify-code-first",
    )
    repeated = verification.verify(
        registration_session=registration.registration_session,
        code=code,
        token=None,
        idempotency_key="verify-code-repeated",
    )

    assert len(code) == 6 and code.isdigit()
    assert challenge.code_hash != code
    assert first.status == repeated.status == AccountStatus.PENDING_MATRIX
    with factory() as session:
        assert session.get(User, registration.user_id).status == AccountStatus.PENDING_MATRIX
        assert session.scalar(
            select(func.count()).select_from(OutboxEvent).where(
                OutboxEvent.event_type == "identity.matrix.provision.requested"
            )
        ) == 1


def test_signed_link_token_verifies_registration(verification_components) -> None:
    factory, _, _, codec, _, verification = verification_components
    registration = _register(verification_components, "link")
    challenge = _challenge(factory, registration.user_id)
    token = codec.link_token(challenge.id)

    result = verification.verify(
        registration_session=registration.registration_session,
        code=None,
        token=token,
        idempotency_key="verify-link",
    )

    assert challenge.link_token_hash != token
    assert result.status == AccountStatus.PENDING_MATRIX


def test_verification_expires_after_ten_minutes(verification_components) -> None:
    factory, clock, _, codec, _, verification = verification_components
    registration = _register(verification_components, "expired")
    challenge = _challenge(factory, registration.user_id)
    clock["now"] += timedelta(minutes=10, seconds=1)

    with pytest.raises(AppError) as exc_info:
        verification.verify(
            registration_session=registration.registration_session,
            code=codec.verification_code(challenge.id),
            token=None,
            idempotency_key="verify-expired",
        )

    assert exc_info.value.code == "EMAIL_VERIFICATION_EXPIRED"


def test_five_failed_attempts_lock_the_challenge(verification_components) -> None:
    factory, _, _, codec, _, verification = verification_components
    registration = _register(verification_components, "attempts")
    challenge = _challenge(factory, registration.user_id)
    correct_code = codec.verification_code(challenge.id)
    wrong_code = "000000" if correct_code != "000000" else "999999"

    for attempt in range(5):
        with pytest.raises(AppError) as exc_info:
            verification.verify(
                registration_session=registration.registration_session,
                code=wrong_code,
                token=None,
                idempotency_key=f"verify-wrong-{attempt}",
            )
        assert exc_info.value.code in {
            "EMAIL_VERIFICATION_INVALID",
            "EMAIL_VERIFICATION_ATTEMPTS_EXHAUSTED",
        }

    with pytest.raises(AppError) as exc_info:
        verification.verify(
            registration_session=registration.registration_session,
            code=correct_code,
            token=None,
            idempotency_key="verify-after-exhaustion",
        )
    assert exc_info.value.code == "EMAIL_VERIFICATION_ATTEMPTS_EXHAUSTED"
    with factory() as session:
        assert session.get(EmailVerificationChallenge, challenge.id).attempt_count == 5


def test_resend_waits_sixty_seconds_and_invalidates_old_code_and_link(
    verification_components,
) -> None:
    factory, clock, _, codec, _, verification = verification_components
    registration = _register(verification_components, "resend")
    old_challenge = _challenge(factory, registration.user_id)
    old_code = codec.verification_code(old_challenge.id)
    old_token = codec.link_token(old_challenge.id)

    with pytest.raises(AppError) as exc_info:
        verification.resend(
            registration_session=registration.registration_session,
            idempotency_key="resend-too-soon",
        )
    assert exc_info.value.code == "EMAIL_VERIFICATION_RESEND_TOO_SOON"

    clock["now"] += timedelta(seconds=60)
    resent = verification.resend(
        registration_session=registration.registration_session,
        idempotency_key="resend-accepted",
    )
    replay = verification.resend(
        registration_session=registration.registration_session,
        idempotency_key="resend-accepted",
    )
    new_challenge = _challenge(factory, registration.user_id)

    assert resent == replay
    assert resent.resend_after_seconds == 60
    assert new_challenge.id != old_challenge.id
    with factory() as session:
        invalidated = session.get(EmailVerificationChallenge, old_challenge.id)
        assert invalidated.invalidated_at == invalidated.created_at + timedelta(seconds=60)
        assert invalidated.registration_session_hash is None

    for credential in ({"code": old_code, "token": None}, {"code": None, "token": old_token}):
        with pytest.raises(AppError) as exc_info:
            verification.verify(
                registration_session=registration.registration_session,
                idempotency_key=f"old-{credential['code'] or 'token'}",
                **credential,
            )
        assert exc_info.value.code == "EMAIL_VERIFICATION_INVALID"

    verified = verification.verify(
        registration_session=registration.registration_session,
        code=codec.verification_code(new_challenge.id),
        token=None,
        idempotency_key="verify-new-code",
    )
    assert verified.status == AccountStatus.PENDING_MATRIX


@pytest.mark.asyncio
async def test_verification_api_is_strict_and_status_never_exposes_user_uuid(
    verification_components,
) -> None:
    factory, _, invitations, codec, _, _ = verification_components
    invitations.issue(
        code="API-VERIFY",
        max_uses=1,
        expires_at=datetime.now(timezone.utc) + timedelta(days=1),
        created_by="admin-1",
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
    app = create_app(settings, session_factory=factory)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        registered = await client.post(
            "/api/v1/auth/register",
            headers={"Idempotency-Key": "api-verification-registration"},
            json={
                "username": "api-user",
                "email": "api-user@example.com",
                "password": "correct horse battery staple",
                "invitation_code": "API-VERIFY",
            },
        )
        registration_session = registered.json()["registration_session"]
        with factory() as session:
            challenge = session.scalar(
                select(EmailVerificationChallenge).where(
                    EmailVerificationChallenge.user_id
                    == session.scalar(select(User.id).where(User.username == "api-user"))
                )
            )
        code = codec.verification_code(challenge.id)
        missing_credential = await client.post(
            "/api/v1/auth/email-verifications/verify",
            headers={"Idempotency-Key": "api-missing-credential"},
            json={"registration_session": registration_session},
        )
        both_credentials = await client.post(
            "/api/v1/auth/email-verifications/verify",
            headers={"Idempotency-Key": "api-both-credentials"},
            json={
                "registration_session": registration_session,
                "code": code,
                "token": codec.link_token(challenge.id),
            },
        )
        short_code = await client.post(
            "/api/v1/auth/email-verifications/verify",
            headers={"Idempotency-Key": "api-short-code"},
            json={"registration_session": registration_session, "code": "123"},
        )
        verified = await client.post(
            "/api/v1/auth/email-verifications/verify",
            headers={"Idempotency-Key": "api-code-verification"},
            json={"registration_session": registration_session, "code": code},
        )
        status = await client.get(
            f"/api/v1/auth/registrations/{registration_session}"
        )

    assert missing_credential.status_code == both_credentials.status_code == 422
    assert short_code.status_code == 422
    assert short_code.json()["error"]["fields"] == [
        {"loc": ["body", "code"], "msg": "请输入 6 位数字验证码", "type": "email_verification_code_invalid"}
    ]
    assert verified.status_code == 202
    assert verified.json() == {"status": "PENDING_MATRIX"}
    assert status.status_code == 200
    assert status.json()["status"] == "PENDING_MATRIX"
    assert "user_id" not in status.json()
