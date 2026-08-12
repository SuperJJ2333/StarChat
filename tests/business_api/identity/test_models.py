from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import create_engine
from sqlalchemy.exc import IntegrityError

from app.core.database import Base, create_session_factory
from app.modules.identity.enums import AccountStatus, RoleCode
from app.modules.identity.models import Invitation, User, UserRole


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
