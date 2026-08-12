from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import create_engine, select

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.core.outbox import OutboxEvent
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
    )

    with pytest.raises(AppError) as exc_info:
        service.register(
            username="bob",
            email="bob@example.com",
            password="correct horse battery staple",
            invitation_code="ONE-USE",
        )

    assert exc_info.value.code == "INVITATION_INVALID"


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
