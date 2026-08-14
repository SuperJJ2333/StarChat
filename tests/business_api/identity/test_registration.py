from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from threading import Barrier

from httpx import ASGITransport, AsyncClient
import pytest
from sqlalchemy import create_engine, func, select

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.core.idempotency import IdempotencyRecord
from app.core.outbox import OutboxEvent
from app.main import create_app
from app.modules.identity.enums import AccountStatus
from app.modules.identity.invitations import InvitationService
from app.modules.identity.models import EmailVerificationChallenge, Invitation, User
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.registration import (
    EmailVerificationService,
    RegistrationService,
    VerificationTokenCodec,
)


@pytest.fixture()
def registration_components():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False})
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime(2026, 8, 12, 8, 0, tzinfo=timezone.utc)
    invitations = InvitationService(factory, now_factory=lambda: now)
    token_codec = VerificationTokenCodec(b"test-email-verification-secret")
    service = RegistrationService(
        factory,
        invitation_service=invitations,
        password_hasher=PasswordHasher(),
        now_factory=lambda: now,
        token_codec=token_codec,
    )
    verifier = EmailVerificationService(factory, token_codec=token_codec, now_factory=lambda: now)
    yield factory, invitations, service, verifier, now
    engine.dispose()


def test_register_consumes_invitation_and_creates_pending_user(registration_components) -> None:
    factory, invitations, service, _, now = registration_components
    invitation = invitations.issue(
        code="WELCOME-001",
        max_uses=1,
        expires_at=now + timedelta(days=1),
        created_by="admin-1",
    )

    result = service.register(
        username=" Alice ",
        email=" Alice@Example.COM ",
        password="correct horse battery staple",
        invitation_code="WELCOME-001",
        idempotency_key="registration-1",
    )

    assert result.verification_token.startswith("email-verification-token") is False
    assert "." in result.verification_token
    with factory() as session:
        user = session.get(User, result.user_id)
        assert user is not None
        assert user.username_normalized == "alice"
        assert user.email_normalized == "alice@example.com"
        assert user.status == AccountStatus.PENDING_EMAIL
        assert user.password_hash != "correct horse battery staple"
        assert session.get(Invitation, invitation.id).use_count == 1
        challenge = session.scalar(
            select(EmailVerificationChallenge).where(
                EmailVerificationChallenge.user_id == result.user_id
            )
        )
        assert challenge is not None
        assert challenge.token_hash != result.verification_token
        email_event = session.scalar(
            select(OutboxEvent).where(
                OutboxEvent.event_type == "identity.email_verification.requested"
            )
        )
        assert email_event.payload["user_id"] == result.user_id


def test_expired_or_consumed_invitation_is_rejected(registration_components) -> None:
    _, invitations, service, _, now = registration_components
    invitations.issue(
        code="ONE-USE",
        max_uses=1,
        expires_at=now + timedelta(days=1),
        created_by="admin-1",
    )
    service.register(
        username="alice",
        email="alice@example.com",
        password="correct horse battery staple",
        invitation_code="ONE-USE",
        idempotency_key="registration-alice",
    )

    with pytest.raises(AppError) as exc_info:
        service.register(
            username="bob",
            email="bob@example.com",
            password="correct horse battery staple",
            invitation_code="ONE-USE",
            idempotency_key="registration-bob",
        )

    assert exc_info.value.code == "INVITATION_EXHAUSTED"


def test_verify_email_moves_user_to_pending_matrix_once(registration_components) -> None:
    factory, invitations, service, verifier, now = registration_components
    invitations.issue(
        code="VERIFY-ME",
        max_uses=1,
        expires_at=now + timedelta(days=1),
        created_by="admin-1",
    )
    result = service.register(
        username="alice",
        email="alice@example.com",
        password="correct horse battery staple",
        invitation_code="VERIFY-ME",
        idempotency_key="registration-verify",
    )

    verified_user_id = verifier.verify(result.verification_token)

    assert verified_user_id == result.user_id
    with factory() as session:
        user = session.get(User, result.user_id)
        assert user.status == AccountStatus.PENDING_MATRIX
        assert user.email_verified_at is not None
        matrix_events = list(
            session.scalars(
                select(OutboxEvent).where(
                    OutboxEvent.event_type == "identity.matrix_provision.requested"
                )
            )
        )
        assert len(matrix_events) == 1

    with pytest.raises(AppError) as exc_info:
        verifier.verify(result.verification_token)
    assert exc_info.value.code == "EMAIL_VERIFICATION_INVALID"


def test_password_hash_can_be_verified_and_rejects_wrong_password() -> None:
    hasher = PasswordHasher()
    encoded = hasher.hash("correct horse battery staple")

    assert encoded.startswith("$argon2id$")
    assert hasher.verify(encoded, "correct horse battery staple") is True
    assert hasher.verify(encoded, "incorrect") is False


@pytest.mark.parametrize(
    ("invitation_code", "expires_delta", "max_uses", "expected_code"),
    [
        ("   ", timedelta(days=1), 1, "INVITATION_REQUIRED"),
        ("MISSING", timedelta(days=1), 1, "INVITATION_INVALID"),
        ("EXPIRED", timedelta(seconds=-1), 1, "INVITATION_EXPIRED"),
    ],
)
def test_registration_rejects_unusable_invitation_with_stable_code(
    registration_components,
    invitation_code,
    expires_delta,
    max_uses,
    expected_code,
) -> None:
    _, invitations, service, _, now = registration_components
    if invitation_code.strip() and invitation_code != "MISSING":
        invitations.issue(
            code=invitation_code,
            max_uses=max_uses,
            expires_at=now + expires_delta,
            created_by="admin-1",
        )

    with pytest.raises(AppError) as exc_info:
        service.register(
            username="alice",
            email="alice@example.com",
            password="correct horse battery staple",
            invitation_code=invitation_code,
            idempotency_key=f"registration-{expected_code}",
        )

    assert exc_info.value.code == expected_code


def test_registration_idempotency_replays_public_session_without_duplicate_writes(
    registration_components,
) -> None:
    factory, invitations, service, _, now = registration_components
    invitation = invitations.issue(
        code="REPLAY-ONCE",
        max_uses=1,
        expires_at=now + timedelta(days=1),
        created_by="admin-1",
    )
    request = {
        "username": "alice",
        "email": "alice@example.com",
        "password": "correct horse battery staple",
        "invitation_code": "REPLAY-ONCE",
        "idempotency_key": "registration-replay",
    }

    first = service.register(**request)
    replay = service.register(**request)

    assert replay.registration_session == first.registration_session
    assert replay.status == AccountStatus.PENDING_EMAIL
    assert replay.resend_after_seconds == 60
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(User)) == 1
        assert session.scalar(select(func.count()).select_from(EmailVerificationChallenge)) == 1
        assert session.scalar(select(func.count()).select_from(OutboxEvent)) == 1
        assert session.scalar(select(func.count()).select_from(IdempotencyRecord)) == 1
        assert session.get(Invitation, invitation.id).use_count == 1


def test_registration_rejects_idempotency_key_reuse_with_different_payload(
    registration_components,
) -> None:
    _, invitations, service, _, now = registration_components
    invitations.issue(
        code="CONFLICT",
        max_uses=2,
        expires_at=now + timedelta(days=1),
        created_by="admin-1",
    )
    service.register(
        username="alice",
        email="alice@example.com",
        password="correct horse battery staple",
        invitation_code="CONFLICT",
        idempotency_key="registration-conflict",
    )

    with pytest.raises(AppError) as exc_info:
        service.register(
            username="bob",
            email="bob@example.com",
            password="correct horse battery staple",
            invitation_code="CONFLICT",
            idempotency_key="registration-conflict",
        )

    assert exc_info.value.code == "IDEMPOTENCY_CONFLICT"


def test_single_use_invitation_allows_only_one_concurrent_registration(tmp_path) -> None:
    database_path = tmp_path / "registration.sqlite3"
    engine = create_engine(
        f"sqlite+pysqlite:///{database_path}",
        connect_args={"check_same_thread": False, "timeout": 10},
    )
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime(2026, 8, 12, 8, 0, tzinfo=timezone.utc)
    invitations = InvitationService(factory, now_factory=lambda: now)
    invitations.issue(
        code="CONCURRENT",
        max_uses=1,
        expires_at=now + timedelta(days=1),
        created_by="admin-1",
    )
    service = RegistrationService(
        factory,
        invitation_service=invitations,
        password_hasher=PasswordHasher(),
        token_codec=VerificationTokenCodec(b"test-email-verification-secret"),
        now_factory=lambda: now,
    )
    barrier = Barrier(2)

    def register(suffix: str):
        barrier.wait()
        try:
            return service.register(
                username=f"user-{suffix}",
                email=f"user-{suffix}@example.com",
                password="correct horse battery staple",
                invitation_code="CONCURRENT",
                idempotency_key=f"concurrent-{suffix}",
            )
        except AppError as exc:
            return exc.code

    try:
        with ThreadPoolExecutor(max_workers=2) as executor:
            outcomes = list(executor.map(register, ("a", "b")))

        assert sum(hasattr(outcome, "registration_session") for outcome in outcomes) == 1
        assert outcomes.count("INVITATION_EXHAUSTED") == 1
        with factory() as session:
            assert session.scalar(select(func.count()).select_from(User)) == 1
    finally:
        engine.dispose()


@pytest.mark.asyncio
async def test_registration_api_requires_idempotency_and_returns_only_public_session(
    registration_components,
) -> None:
    factory, invitations, _, _, now = registration_components
    invitations.issue(
        code="API-REGISTER",
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
    body = {
        "username": "alice",
        "email": "alice@example.com",
        "password": "correct horse battery staple",
        "invitation_code": "API-REGISTER",
    }

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        missing_key = await client.post("/api/v1/auth/register", json=body)
        accepted = await client.post(
            "/api/v1/auth/register",
            headers={"Idempotency-Key": "api-registration"},
            json=body,
        )
        replay = await client.post(
            "/api/v1/auth/register",
            headers={"Idempotency-Key": "api-registration"},
            json=body,
        )

    assert missing_key.status_code == 422
    assert accepted.status_code == replay.status_code == 202
    assert accepted.json() == replay.json()
    assert set(accepted.json()) == {
        "registration_session",
        "status",
        "resend_after_seconds",
    }
    assert accepted.json()["status"] == "PENDING_EMAIL"
    assert "user_id" not in accepted.json()
