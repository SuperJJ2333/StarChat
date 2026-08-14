from datetime import datetime, timedelta, timezone
from importlib import import_module, util

import pytest
from sqlalchemy import create_engine, select

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.core.outbox import OutboxMessage, OutboxEvent
from app.modules.identity.invitations import InvitationService
from app.modules.identity.models import EmailVerificationChallenge
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
