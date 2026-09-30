"""Real queued challenge delivery uses derived codes and stale-contact guards."""
from datetime import datetime, timezone
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from app.core.database import Base
from app.core.outbox import OutboxEvent, OutboxMessage
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User
from app.modules.identity.phone import PhoneOtpService, RecordingSmsSender
from app.modules.identity.registration import VerificationTokenCodec
from app.modules.identity.recovery import PasswordRecoveryService, PasswordResetTokenCodec
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.account_credentials import AccountCredentialsService
from tasks.identity import IdentityEmailVerificationTask
import tasks.identity as identity_tasks
import pytest
from app.modules.identity.models import OtpChallenge
from app.core.errors import AppError


@pytest.mark.parametrize('stage', ['claim', 'finish', 'cleanup'])
def test_new_email_task_persisted_errors_are_sanitized(tmp_path, monkeypatch, stage):
    from app.core.outbox import OutboxConsumer
    from worker import Worker
    engine = create_engine(f"sqlite+pysqlite:///{tmp_path / 'sanitize.db'}")
    Base.metadata.create_all(engine)
    factory = sessionmaker(engine, expire_on_commit=False)
    now = datetime(2026, 9, 26, tzinfo=timezone.utc)
    with factory.begin() as session:
        session.add(User(id='alice', username='alice', username_normalized='alice', email='alice@example.test',
            email_normalized='alice@example.test', email_verified_at=now, password_hash='unused',
            status=AccountStatus.ACTIVE, created_at=now, updated_at=now))
    codec = VerificationTokenCodec(b'test-email-code-secret')
    service = AccountCredentialsService(factory, otp=PhoneOtpService(factory, sender=RecordingSmsSender(),
        secret='test-otp-secret', now=lambda: now), recovery=None,
        email_code_deriver=codec.verification_code, now_factory=lambda: now)
    service.request_password_code(channel='email', target='alice@example.test')
    sentinel = 'alice@example.test OTP_SENTINEL TOKEN_SENTINEL PASSWORD_SENTINEL'
    def fail(*args, **kwargs): raise RuntimeError(sentinel)
    if stage == 'claim': monkeypatch.setattr(AccountCredentialsService, 'claim_email_delivery', fail)
    else: monkeypatch.setattr(AccountCredentialsService, 'finish_email_delivery', fail)
    class Sender:
        def send_email_otp(self, **kwargs):
            if stage == 'cleanup': raise RuntimeError(sentinel)
    task = IdentityEmailVerificationTask(factory, token_codec=codec, public_base_url='https://example.test',
        email_sender=Sender(), now_factory=lambda: now)
    worker = Worker(consumer=OutboxConsumer(factory, now_factory=lambda: now), handlers={'identity.email':task},
        worker_id='test', max_attempts=1, now_factory=lambda: now)
    assert worker.run_once(limit=10) == 1
    with factory() as session:
        row = session.scalar(select(OutboxEvent))
        assert row.status == 'DEAD'
        assert row.last_error == '验证邮件暂不可用'
        for word in sentinel.split(): assert word not in row.last_error
    engine.dispose()


def test_password_email_otp_is_delivered_then_stale_binding_is_rejected(tmp_path):
    engine = create_engine(f"sqlite+pysqlite:///{tmp_path / 'worker-credentials.db'}")
    Base.metadata.create_all(engine)
    factory = sessionmaker(engine, expire_on_commit=False)
    now = datetime(2026, 9, 26, tzinfo=timezone.utc)
    with factory.begin() as session:
        session.add(User(id='alice', username='alice', username_normalized='alice', email='alice@example.test',
            email_normalized='alice@example.test', email_verified_at=now, password_hash='unused', status=AccountStatus.ACTIVE,
            created_at=now, updated_at=now))
    codec = VerificationTokenCodec(b'test-email-code-secret')
    service = AccountCredentialsService(factory, otp=PhoneOtpService(factory, sender=RecordingSmsSender(), secret='test-otp-secret', now=lambda: now),
        recovery=PasswordRecoveryService(factory, password_hasher=PasswordHasher(), token_codec=PasswordResetTokenCodec(b'test-reset-secret')),
        email_code_deriver=codec.verification_code, now_factory=lambda: now)
    service.request_password_code(channel='email', target='alice@example.test')
    with factory() as session:
        event = session.scalar(select(OutboxEvent))
        message = OutboxMessage(event.id, event.topic, event.event_type, event.aggregate_type, event.aggregate_id, event.payload, {}, 1)
    class Sender:
        messages = []
        def send_email_otp(self, **kwargs): self.messages.append(kwargs)
    sender = Sender()
    task = IdentityEmailVerificationTask(factory, token_codec=codec, public_base_url='https://example.test', email_sender=sender, now_factory=lambda: now)
    task(message)
    assert sender.messages == [{'recipient': 'alice@example.test', 'code': codec.verification_code(event.aggregate_id), 'purpose': 'password_reset_email'}]
    task(message)
    assert len(sender.messages) == 1
    with factory.begin() as session:
        session.get(User, 'alice').email_normalized = 'new@example.test'
    task(message)
    assert len(sender.messages) == 1
    engine.dispose()


def test_security_observation_accepts_only_sanitized_identity_events():
    assert hasattr(identity_tasks, 'AccountCredentialsObservationTask'), 'new security Outbox has no consumer'
    import pytest
    task = identity_tasks.AccountCredentialsObservationTask()
    valid = OutboxMessage('event', 'identity.account_credentials', 'identity.password.reset', 'user', 'alice',
        {'user_id': 'alice', 'reason_code': 'PASSWORD_RESET'}, {}, 1)
    task(valid)
    invalid = OutboxMessage('event', 'identity.account_credentials', 'identity.password.reset', 'user', 'alice',
        {'user_id': 'alice', 'reason_code': 'PASSWORD_RESET', 'password': 'must-not-appear'}, {}, 1)
    with pytest.raises(ValueError, match='ACCOUNT_CREDENTIALS_EVENT_INVALID'):
        task(invalid)


@pytest.mark.parametrize('outcome', ['smtp_failure', 'late_binding_change'])
def test_email_failure_or_late_binding_never_activates_pending_otp(tmp_path, outcome):
    engine = create_engine(f"sqlite+pysqlite:///{tmp_path / 'email-delivery.db'}")
    Base.metadata.create_all(engine)
    factory = sessionmaker(engine, expire_on_commit=False)
    now = datetime(2026, 9, 26, tzinfo=timezone.utc)
    with factory.begin() as session:
        session.add(User(id='alice', username='alice', username_normalized='alice', email='alice@example.test',
            email_normalized='alice@example.test', email_verified_at=now, password_hash='unused', status=AccountStatus.ACTIVE,
            created_at=now, updated_at=now))
    codec = VerificationTokenCodec(b'test-email-code-secret')
    service = AccountCredentialsService(factory, otp=PhoneOtpService(factory, sender=RecordingSmsSender(), secret='test-otp-secret', now=lambda: now),
        recovery=None, email_code_deriver=codec.verification_code, now_factory=lambda: now)
    service.request_password_code(channel='email', target='alice@example.test')
    with factory() as session:
        event = session.scalar(select(OutboxEvent))
        message = OutboxMessage(event.id, event.topic, event.event_type, event.aggregate_type, event.aggregate_id, event.payload, {}, 1)
    class Sender:
        calls = 0
        def send_email_otp(self, **kwargs):
            self.calls += 1
            if outcome == 'smtp_failure': raise RuntimeError('sensitive provider details must be sanitized')
            with factory.begin() as session:
                session.get(User, 'alice').email_normalized = 'changed@example.test'
    sender = Sender()
    task = IdentityEmailVerificationTask(factory, token_codec=codec, public_base_url='https://example.test', email_sender=sender, now_factory=lambda: now)
    if outcome == 'smtp_failure':
        with pytest.raises(AppError, match='验证邮件暂不可用'): task(message)
    else:
        task(message)
    task(message)
    assert sender.calls == 1
    with factory() as session:
        row = session.get(OtpChallenge, event.aggregate_id)
        assert row.attempts_left == 0 and row.invalidated_at is not None
    with pytest.raises(AppError): service.verify_password_code(channel='email', target='alice@example.test', code=codec.verification_code(event.aggregate_id))
    engine.dispose()
