"""BUG-12（D4）：注册验证完成前允许更换邮箱——作废旧挑战、新码发新邮箱。

边界（用户已批准）：邮箱验证通过后不可在此换邮箱（走账号设置换绑）。
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import create_engine, select

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.core.errors import AppError
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
def change_components():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False})
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    clock = {"now": datetime(2026, 9, 19, 9, 0, tzinfo=timezone.utc)}

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
    invitation_code = f"CHANGE-{suffix}"
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


def _active_challenge(factory, user_id: str) -> EmailVerificationChallenge:
    with factory() as session:
        return session.scalar(
            select(EmailVerificationChallenge).where(
                EmailVerificationChallenge.user_id == user_id,
                EmailVerificationChallenge.invalidated_at.is_(None),
            )
        )


def test_change_email_rebinds_session_and_sends_code_to_new_address(
    change_components,
) -> None:
    factory, clock, _, codec, registration, verification = change_components
    registered = _register(change_components, "change")
    old_challenge = _active_challenge(factory, registered.user_id)

    result = verification.change_email(
        registration_session=registered.registration_session,
        new_email="New.Address@Example.com",
        idempotency_key="change-1",
    )

    assert result.status == AccountStatus.PENDING_EMAIL
    with factory() as session:
        user = session.get(User, registered.user_id)
        assert user.email_normalized == "new.address@example.com"
        # 旧挑战作废；新挑战绑定同一注册会话（客户端 session 不变）。
        assert (
            session.get(EmailVerificationChallenge, old_challenge.id).invalidated_at
            is not None
        )
        new_challenge = _active_challenge(factory, registered.user_id)
        assert new_challenge is not None
        assert new_challenge.id != old_challenge.id
        assert new_challenge.registration_session_hash == (
            codec.registration_session_hash(registered.registration_session)
        )

    # 新挑战的验证码可在新邮箱地址完成验证（验证码按挑战派生）。
    code = codec.verification_code(new_challenge.id)
    verified = verification.verify(
        registration_session=registered.registration_session,
        code=code,
        token=None,
        idempotency_key="verify-after-change",
    )
    assert verified.status == AccountStatus.PENDING_MATRIX


def test_change_email_rejects_email_owned_by_another_account(change_components) -> None:
    factory, _, _, _, registration, verification = change_components
    registered = _register(change_components, "a")
    other = _register(change_components, "b")

    with pytest.raises(AppError) as error:
        verification.change_email(
            registration_session=registered.registration_session,
            new_email=f"user-b@example.com",
            idempotency_key="change-dup",
        )
    assert error.value.code == "EMAIL_ALREADY_REGISTERED"
    with factory() as session:
        assert (
            session.get(User, registered.user_id).email_normalized
            == "user-a@example.com"
        ), "失败的换邮箱不得改动原邮箱"
        assert other is not None


def test_change_email_rejected_after_email_verified(change_components) -> None:
    factory, _, _, codec, registration, verification = change_components
    registered = _register(change_components, "done")
    challenge = _active_challenge(factory, registered.user_id)
    code = codec.verification_code(challenge.id)
    verification.verify(
        registration_session=registered.registration_session,
        code=code,
        token=None,
        idempotency_key="verify-first",
    )
    assert session_user_status(factory, registered.user_id) == AccountStatus.PENDING_MATRIX

    with pytest.raises(AppError) as error:
        verification.change_email(
            registration_session=registered.registration_session,
            new_email="another@example.com",
            idempotency_key="change-after-verify",
        )
    assert error.value.code == "EMAIL_VERIFICATION_INVALID"
    # 边界（D4）：验证完成后不可再在此换邮箱。


def session_user_status(factory, user_id: str) -> AccountStatus:
    with factory() as session:
        return session.get(User, user_id).status
