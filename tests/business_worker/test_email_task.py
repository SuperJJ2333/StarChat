from datetime import datetime, timedelta, timezone
from pathlib import Path
import sys

from sqlalchemy import create_engine

from app.core.database import Base, create_session_factory
from app.core.outbox import OutboxMessage
from app.modules.identity.enums import AccountStatus
from app.modules.identity.invitations import hash_opaque_token
from app.modules.identity.models import EmailVerificationChallenge, User
from app.modules.identity.registration import VerificationTokenCodec

TASKS = Path(__file__).parents[2] / "services" / "business-worker" / "app" / "tasks"
sys.path.insert(0, str(TASKS))

from email_task import EmailVerificationTask  # noqa: E402


def test_email_task_reconstructs_verification_link_without_storing_plain_token() -> None:
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False})
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime(2026, 8, 12, 8, 0, tzinfo=timezone.utc)
    codec = VerificationTokenCodec(b"test-email-verification-secret")
    token = codec.issue("challenge-1")
    with factory.begin() as session:
        session.add(
            User(
                id="user-1",
                username="alice",
                username_normalized="alice",
                email="alice@example.com",
                email_normalized="alice@example.com",
                password_hash="hash",
                status=AccountStatus.PENDING_EMAIL,
                created_at=now,
                updated_at=now,
            )
        )
        session.add(
            EmailVerificationChallenge(
                id="challenge-1",
                user_id="user-1",
                token_hash=hash_opaque_token(token),
                expires_at=now + timedelta(hours=24),
                attempt_count=0,
                created_at=now,
            )
        )

    sent = []
    task = EmailVerificationTask(
        factory,
        token_codec=codec,
        public_base_url="https://example.test",
        sender=lambda email, link: sent.append((email, link)),
    )
    task(
        OutboxMessage(
            id="event-1",
            topic="identity.email",
            event_type="identity.email_verification.requested",
            aggregate_type="email_verification_challenge",
            aggregate_id="challenge-1",
            payload={"user_id": "user-1", "challenge_id": "challenge-1"},
            headers={},
            attempt_count=1,
        )
    )

    assert sent == [("alice@example.com", f"https://example.test/verify-email?token={token}")]
    with factory() as session:
        challenge = session.get(EmailVerificationChallenge, "challenge-1")
        assert challenge.token_hash != token
    engine.dispose()
