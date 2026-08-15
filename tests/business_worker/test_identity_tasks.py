from datetime import datetime, timedelta, timezone
from importlib import import_module, util

import pytest
from sqlalchemy import create_engine, select

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.core.outbox import OutboxMessage, OutboxEvent
from app.modules.identity.invitations import InvitationService
from app.modules.identity.models import EmailVerificationChallenge, User
from app.modules.identity.enums import AccountStatus
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.registration import RegistrationService, VerificationTokenCodec


def _identity_module():
    assert util.find_spec("tasks.identity") is not None
    return import_module("tasks.identity")


class RecordingSender:
    def __init__(self):
        self.messages = []

    def send_email_verification(self, *, recipient, code, link):
        self.messages.append((recipient, code, link))


def test_identity_task_derives_both_credentials_without_outbox_plaintext() -> None:
    module = _identity_module()
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False})
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime(2026, 8, 14, 8, 0, tzinfo=timezone.utc)
    codec = VerificationTokenCodec(b"test-email-verification-secret")
    invitations = InvitationService(factory, now_factory=lambda: now)
    invitations.issue(
        code="WORKER-EMAIL",
        max_uses=1,
        expires_at=now + timedelta(days=1),
        created_by="admin-1",
    )
    registration = RegistrationService(
        factory,
        invitation_service=invitations,
        password_hasher=PasswordHasher(),
        token_codec=codec,
        now_factory=lambda: now,
    ).register(
        username="alice",
        email="alice@example.test",
        password="correct horse battery staple",
        invitation_code="WORKER-EMAIL",
        idempotency_key="worker-email-registration",
    )
    with factory() as session:
        event = session.scalar(
            select(OutboxEvent).where(OutboxEvent.topic == "identity.email")
        )
        challenge = session.scalar(
            select(EmailVerificationChallenge).where(
                EmailVerificationChallenge.user_id == registration.user_id
            )
        )
    payload_text = str(event.payload)
    assert "correct horse battery staple" not in payload_text
    assert codec.verification_code(challenge.id) not in payload_text
    assert codec.link_token(challenge.id) not in payload_text

    sender = RecordingSender()
    task = module.IdentityEmailVerificationTask(
        factory,
        token_codec=codec,
        public_base_url="https://example.test",
        email_sender=sender,
        now_factory=lambda: now,
    )
    task(
        OutboxMessage(
            id=event.id,
            topic=event.topic,
            event_type=event.event_type,
            aggregate_type=event.aggregate_type,
            aggregate_id=event.aggregate_id,
            payload=event.payload,
            headers={},
            attempt_count=1,
        )
    )

    assert sender.messages == [
        (
            "alice@example.test",
            codec.verification_code(challenge.id),
            f"https://example.test/verify-email?token={codec.link_token(challenge.id)}",
        )
    ]
    engine.dispose()


def test_identity_task_rejects_unsupported_event_without_sending() -> None:
    module = _identity_module()
    sender = RecordingSender()
    task = module.IdentityEmailVerificationTask(
        lambda: None,
        token_codec=VerificationTokenCodec(b"test-email-verification-secret"),
        public_base_url="https://example.test",
        email_sender=sender,
    )

    with pytest.raises(AppError) as exc_info:
        task(
            OutboxMessage(
                id="event-1",
                topic="identity.email",
                event_type="identity.email.unsupported",
                aggregate_type="email_verification_challenge",
                aggregate_id="challenge-1",
                payload={"challenge_id": "challenge-1"},
                headers={},
                attempt_count=1,
            )
        )

    assert exc_info.value.code == "EMAIL_EVENT_UNSUPPORTED"
    assert sender.messages == []


class RecordingProfileGateway:
    def __init__(self, *, fail_profile_update=False):
        self.calls = []
        self.fail_profile_update = fail_profile_update

    def upload_profile_media(self, content, mime_type):
        self.calls.append(("upload", content, mime_type))
        return "mxc://matrix.example.test/avatar-1"

    def set_user_profile(self, matrix_user_id, *, display_name, avatar_url):
        self.calls.append(("profile", matrix_user_id, display_name, avatar_url))
        if self.fail_profile_update:
            raise AppError(
                code="MATRIX_PROFILE_SYNC_FAILED",
                message="profile update failed",
                status_code=502,
            )


class MemoryAvatarReader:
    def __init__(self, objects):
        self.objects = objects

    def get(self, object_key):
        return self.objects[object_key]


def _profile_message(user_id="user-1"):
    return OutboxMessage(
        id="profile-event-1",
        topic="identity.profile",
        event_type="identity.profile.changed",
        aggregate_type="user",
        aggregate_id=user_id,
        payload={"user_id": user_id},
        headers={},
        attempt_count=1,
    )


def _active_profile_user(now):
    return User(
        id="user-1",
        username="alice",
        username_normalized="alice",
        email="alice@example.test",
        email_normalized="alice@example.test",
        password_hash="hash",
        status=AccountStatus.ACTIVE,
        matrix_user_id="@alice:matrix.example.test",
        email_verified_at=now,
        nickname="Alice Chen",
        signature="hello",
        avatar_object_key="avatars/user-1/avatar.png",
        profile_updated_at=now,
        matrix_profile_synced_at=None,
        matrix_avatar_source_key=None,
        matrix_avatar_mxc_uri=None,
        created_at=now,
        updated_at=now,
    )


def test_matrix_profile_task_uploads_avatar_before_mxc_update_and_replay_is_idempotent() -> None:
    module = _identity_module()
    task_type = module.MatrixProfileSyncTask
    engine = create_engine(
        "sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}
    )
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime(2026, 8, 15, 9, 0, tzinfo=timezone.utc)
    with factory.begin() as session:
        session.add(_active_profile_user(now))
    gateway = RecordingProfileGateway()
    task = task_type(
        factory,
        gateway=gateway,
        avatar_reader=MemoryAvatarReader(
            {"avatars/user-1/avatar.png": b"real-private-avatar"}
        ),
        now_factory=lambda: now + timedelta(seconds=1),
    )

    task(_profile_message())
    task(_profile_message())

    assert gateway.calls == [
        ("upload", b"real-private-avatar", "image/png"),
        (
            "profile",
            "@alice:matrix.example.test",
            "Alice Chen",
            "mxc://matrix.example.test/avatar-1",
        ),
    ]
    with factory() as session:
        user = session.get(User, "user-1")
        assert user.matrix_avatar_source_key == "avatars/user-1/avatar.png"
        assert user.matrix_avatar_mxc_uri == "mxc://matrix.example.test/avatar-1"
        assert user.matrix_profile_synced_at is not None
    engine.dispose()


def test_matrix_profile_sync_failure_does_not_rollback_business_profile() -> None:
    module = _identity_module()
    task_type = module.MatrixProfileSyncTask
    engine = create_engine(
        "sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}
    )
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime(2026, 8, 15, 9, 0, tzinfo=timezone.utc)
    with factory.begin() as session:
        session.add(_active_profile_user(now))
    gateway = RecordingProfileGateway(fail_profile_update=True)
    task = task_type(
        factory,
        gateway=gateway,
        avatar_reader=MemoryAvatarReader(
            {"avatars/user-1/avatar.png": b"real-private-avatar"}
        ),
    )

    with pytest.raises(AppError, match="profile update failed"):
        task(_profile_message())

    with factory() as session:
        user = session.get(User, "user-1")
        assert user.nickname == "Alice Chen"
        assert user.avatar_object_key == "avatars/user-1/avatar.png"
        assert user.matrix_profile_synced_at is None
        assert user.matrix_avatar_mxc_uri == "mxc://matrix.example.test/avatar-1"
    engine.dispose()
