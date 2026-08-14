from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import create_engine
from sqlalchemy.exc import IntegrityError

from app.core.database import Base, create_session_factory
from app.modules.identity.enums import AccountStatus, RoleCode
from app.modules.identity.models import EmailVerificationChallenge, Invitation, User, UserRole


@pytest.fixture()
def session_factory():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False})
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    yield factory
    engine.dispose()


def test_user_starts_pending_email_without_phone_or_real_name(session_factory) -> None:
    now = datetime.now(timezone.utc)
    with session_factory.begin() as session:
        user = User(
            id="user-1",
            username="alice",
            username_normalized="alice",
            email="alice@example.com",
            email_normalized="alice@example.com",
            password_hash="argon2id-hash",
            status=AccountStatus.PENDING_EMAIL,
            created_at=now,
            updated_at=now,
        )
        session.add(user)

    assert not hasattr(user, "phone")
    assert not hasattr(user, "real_name")
    assert user.status == AccountStatus.PENDING_EMAIL


def test_normalized_username_and_email_are_unique(session_factory) -> None:
    now = datetime.now(timezone.utc)
    with pytest.raises(IntegrityError):
        with session_factory.begin() as session:
            for suffix in ("1", "2"):
                session.add(
                    User(
                        id=f"user-{suffix}",
                        username=f"Alice{suffix}",
                        username_normalized="alice",
                        email=f"alice{suffix}@example.com",
                        email_normalized=f"alice{suffix}@example.com",
                        password_hash="hash",
                        status=AccountStatus.PENDING_EMAIL,
                        created_at=now,
                        updated_at=now,
                    )
                )


def test_invitation_and_role_assignment_are_persisted(session_factory) -> None:
    now = datetime.now(timezone.utc)
    with session_factory.begin() as session:
        session.add(
            Invitation(
                id="invite-1",
                code_hash="sha256-hash",
                max_uses=2,
                use_count=0,
                expires_at=now + timedelta(days=1),
                created_by="admin-1",
                created_at=now,
            )
        )
        session.add(
            UserRole(
                id="role-1",
                user_id="user-1",
                role_code=RoleCode.SUPPORT_AGENT,
                assigned_by="admin-1",
                assigned_at=now,
            )
        )

    with session_factory() as session:
        assert session.get(Invitation, "invite-1").remaining_uses == 2
        assert session.get(UserRole, "role-1").role_code == RoleCode.SUPPORT_AGENT


def test_user_profile_defaults_are_persisted_without_plaintext_profile_secrets(
    session_factory,
) -> None:
    now = datetime.now(timezone.utc)
    with session_factory.begin() as session:
        session.add(
            User(
                id="user-profile",
                username="alice",
                username_normalized="alice",
                email="alice@example.com",
                email_normalized="alice@example.com",
                password_hash="argon2id-hash",
                status=AccountStatus.PENDING_EMAIL,
                created_at=now,
                updated_at=now,
            )
        )

    with session_factory() as session:
        user = session.get(User, "user-profile")
        assert user.nickname == "alice"
        assert user.signature is None
        assert user.avatar_object_key is None
        assert user.profile_updated_at == user.created_at


def test_email_verification_challenge_persists_only_hashed_dual_channel_values(
    session_factory,
) -> None:
    now = datetime.now(timezone.utc)
    with session_factory.begin() as session:
        session.add(
            User(
                id="user-verification",
                username="alice",
                username_normalized="alice-verification",
                email="verify@example.com",
                email_normalized="verify@example.com",
                password_hash="argon2id-hash",
                status=AccountStatus.PENDING_EMAIL,
                created_at=now,
                updated_at=now,
            )
        )
        session.add(
            EmailVerificationChallenge(
                id="challenge-1",
                user_id="user-verification",
                token_hash="legacy-link-token-hash",
                registration_session_hash="registration-session-hash",
                code_hash="verification-code-hash",
                link_token_hash="verification-link-token-hash",
                expires_at=now + timedelta(minutes=10),
                resend_available_at=now + timedelta(seconds=60),
                attempt_count=0,
                created_at=now,
            )
        )

    with session_factory() as session:
        challenge = session.get(EmailVerificationChallenge, "challenge-1")
        assert challenge.registration_session_hash == "registration-session-hash"
        assert challenge.code_hash == "verification-code-hash"
        assert challenge.link_token_hash == "verification-link-token-hash"
        assert challenge.resend_available_at == challenge.created_at + timedelta(seconds=60)
        assert challenge.attempt_count == 0
        assert challenge.invalidated_at is None

    mapped_names = set(EmailVerificationChallenge.__mapper__.attrs.keys())
    assert "code" not in mapped_names
    assert "link_token" not in mapped_names
    assert "registration_session" not in mapped_names
