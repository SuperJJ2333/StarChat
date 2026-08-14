from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import create_engine, event, select

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.modules.identity.enums import AccountStatus, HoldType
from app.modules.identity.models import (
    Device,
    RefreshTokenFamily,
    SecurityHold,
    User,
)
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.recovery import PasswordRecoveryService, PasswordResetTokenCodec
from app.modules.identity.tokens import TokenService


@pytest.fixture()
def identity_components():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False})
    @event.listens_for(engine, "connect")
    def enable_foreign_keys(dbapi_connection, _connection_record):
        dbapi_connection.execute("PRAGMA foreign_keys=ON")
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime(2026, 8, 12, 8, 0, tzinfo=timezone.utc)
    hasher = PasswordHasher()
    with factory.begin() as session:
        session.add(
            User(
                id="user-1",
                username="alice",
                username_normalized="alice",
                email="alice@example.com",
                email_normalized="alice@example.com",
                password_hash=hasher.hash("correct horse battery staple"),
                status=AccountStatus.ACTIVE,
                matrix_user_id="@alice:matrix.localhost",
                email_verified_at=now,
                created_at=now,
                updated_at=now,
            )
        )
    tokens = TokenService(
        factory,
        jwt_secret="test-jwt-secret-at-least-thirty-two-bytes",
        jwt_issuer="liuhetong",
        now_factory=lambda: now,
    )
    recovery = PasswordRecoveryService(
        factory,
        password_hasher=hasher,
        token_codec=PasswordResetTokenCodec(b"test-password-reset-secret"),
        now_factory=lambda: now,
    )
    yield factory, tokens, recovery, hasher, now
    engine.dispose()


def test_refresh_token_rotates_and_reuse_revokes_family(identity_components) -> None:
    factory, tokens, _, _, _ = identity_components
    pair = tokens.issue_pair(
        user_id="user-1", device_key="ios-device-1", display_name="Alice iPhone"
    )

    rotated = tokens.rotate(pair.refresh_token)
    assert rotated.refresh_token != pair.refresh_token
    claims = tokens.decode_access_token(rotated.access_token)
    assert claims["sub"] == "user-1"
    assert claims["device_id"] == pair.device_id

    with pytest.raises(AppError) as exc_info:
        tokens.rotate(pair.refresh_token)
    assert exc_info.value.code == "REFRESH_TOKEN_REUSED"

    with factory() as session:
        family = session.get(RefreshTokenFamily, pair.family_id)
        assert family.revoked_at is not None
        assert family.revoke_reason == "TOKEN_REUSE"


def test_device_revocation_revokes_its_token_families(identity_components) -> None:
    factory, tokens, _, _, _ = identity_components
    pair = tokens.issue_pair(
        user_id="user-1", device_key="android-1", display_name="Alice Android"
    )

    devices = tokens.list_devices("user-1")
    assert [device.id for device in devices] == [pair.device_id]
    tokens.revoke_device(user_id="user-1", device_id=pair.device_id)

    with pytest.raises(AppError) as exc_info:
        tokens.rotate(pair.refresh_token)
    assert exc_info.value.code == "REFRESH_TOKEN_INVALID"
    with factory() as session:
        assert session.get(Device, pair.device_id).revoked_at is not None


def test_suspended_user_cannot_rotate_refresh_token(identity_components) -> None:
    factory, tokens, _, _, _ = identity_components
    pair = tokens.issue_pair(
        user_id="user-1", device_key="android-2", display_name="Alice Android"
    )
    with factory.begin() as session:
        session.get(User, "user-1").status = AccountStatus.SUSPENDED

    with pytest.raises(AppError) as exc_info:
        tokens.rotate(pair.refresh_token)

    assert exc_info.value.code == "ACCOUNT_NOT_ACTIVE"
    assert exc_info.value.status_code == 403


def test_password_reset_revokes_sessions_and_adds_24_hour_withdrawal_hold(
    identity_components,
) -> None:
    factory, tokens, recovery, hasher, now = identity_components
    pair = tokens.issue_pair(
        user_id="user-1", device_key="web-1", display_name="Browser"
    )
    reset_token = recovery.request("alice@example.com")

    recovery.reset(reset_token, "a new correct horse battery staple")

    with pytest.raises(AppError):
        tokens.rotate(pair.refresh_token)
    with factory() as session:
        user = session.get(User, "user-1")
        assert hasher.verify(user.password_hash, "a new correct horse battery staple")
        hold = session.scalar(select(SecurityHold).where(SecurityHold.user_id == "user-1"))
        assert hold.hold_type == HoldType.WITHDRAWAL
        assert hold.reason_code == "PASSWORD_RESET"
        starts_at = hold.starts_at.replace(tzinfo=timezone.utc)
        ends_at = hold.ends_at.replace(tzinfo=timezone.utc)
        assert ends_at - starts_at == timedelta(hours=24)
        assert starts_at == now


def test_password_recovery_does_not_reveal_unknown_email(identity_components) -> None:
    _, _, recovery, _, _ = identity_components

    assert recovery.request("missing@example.com") is None
