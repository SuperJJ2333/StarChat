"""ADR-0085 concurrent proof consumption in a loopback-only disposable database."""
import os
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone, timedelta
from threading import Event
import time
from uuid import uuid4

import pytest
from sqlalchemy import create_engine, select, text, event
from sqlalchemy.engine import make_url
from sqlalchemy.orm import sessionmaker

from app.core.database import Base
from app.core.errors import AppError
from app.modules.audit.models import AuditEvent
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import OtpChallenge, SecurityHold, User
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.phone import PhoneOtpService, RecordingSmsSender
from app.modules.identity.recovery import PasswordRecoveryService, PasswordResetTokenCodec
from app.modules.identity.registration import VerificationTokenCodec
from test_account_credentials import service, email_code, deliver_phone, deliver_email_challenge


@pytest.fixture
def pg_env():
    url = os.environ.get('ACCOUNT_CREDENTIALS_POSTGRES_URL')
    if not url:
        pytest.skip('disposable loopback PostgreSQL URL not provided')
    parsed = make_url(url)
    assert parsed.host == '127.0.0.1' and parsed.database == 'credentials_test'
    schema = 'account_credentials_' + uuid4().hex
    engine = create_engine(url, connect_args={'options': '-csearch_path=' + schema + ' -clock_timeout=5000 -cstatement_timeout=15000'}, pool_size=12)
    assert engine.dialect.name == 'postgresql'
    with engine.begin() as connection:
        connection.execute(text('CREATE SCHEMA ' + schema))
    Base.metadata.create_all(engine)
    factory = sessionmaker(engine, expire_on_commit=False)
    clock = [datetime(2026, 9, 26, tzinfo=timezone.utc)]
    hasher = PasswordHasher()
    with factory.begin() as session:
        for name, number in (('alice', '1'), ('bob', '2')):
            session.add(User(id=name, username=name, username_normalized=name, email=f'{name}@example.test',
                email_normalized=f'{name}@example.test', email_verified_at=clock[0],
                phone='+861380000000' + number, phone_normalized='+861380000000' + number,
                phone_verified_at=clock[0], password_hash=hasher.hash('old-password-123'),
                status=AccountStatus.ACTIVE, created_at=clock[0], updated_at=clock[0]))
    sender = RecordingSmsSender()
    otp = PhoneOtpService(factory, sender=sender, secret='test-otp-secret', now=lambda: clock[0])
    codec = VerificationTokenCodec(b'test-email-code-secret')
    recovery = PasswordRecoveryService(factory, password_hasher=hasher,
        token_codec=PasswordResetTokenCodec(b'test-reset-secret'), now_factory=lambda: clock[0])
    try:
        yield factory, otp, codec, recovery, sender, clock
    finally:
        assert schema.startswith('account_credentials_') and len(schema) == 52
        with engine.begin() as connection:
            connection.execute(text('DROP SCHEMA ' + schema + ' CASCADE'))
        engine.dispose()


def attempt(operation):
    try:
        return operation()
    except AppError as error:
        return error.code


@pytest.mark.parametrize('kind', ['grant', 'legacy_link', 'otp'])
def test_lock_wait_crossing_utc_expiry_is_rejected(pg_env, kind):
    api = service(pg_env)
    if kind == 'legacy_link':
        token = pg_env[3].request('alice@example.test')
        operation = lambda: pg_env[3].reset(token, 'new-password-123')
        # Existing links use a longer TTL; the same lock-time recheck applies.
        from app.modules.identity.models import PasswordResetChallenge
        with pg_env[0].begin() as session:
            session.scalar(select(PasswordResetChallenge)).expires_at = pg_env[5][0] + timedelta(seconds=300)
    else:
        api.request_password_code(channel='email', target='alice@example.test')
        code = email_code(pg_env, 'password_reset_email')
        if kind == 'grant':
            token = api.verify_password_code(channel='email', target='alice@example.test', code=code)['reset_token']
            operation = lambda: api.reset_password(token=token, new_password='new-password-123')
        else:
            operation = lambda: api.verify_password_code(channel='email', target='alice@example.test', code=code)
    pg_env[5][0] += timedelta(seconds=299)
    waiting = Event()
    engine = pg_env[0].kw['bind']
    def before_execute(conn, cursor, statement, parameters, context, executemany):
        if 'FOR UPDATE' in statement and 'FROM users' in statement:
            waiting.set()
    with pg_env[0].begin() as lock:
        lock.scalar(select(User).where(User.id == 'alice').with_for_update())
        event.listen(engine, 'before_cursor_execute', before_execute)
        with ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(attempt, operation)
            assert waiting.wait(2), 'worker did not reach user lock'
            pg_env[5][0] += timedelta(seconds=2)
            lock.commit()
            result = future.result(timeout=3)
        event.remove(engine, 'before_cursor_execute', before_execute)
    assert result == 'PASSWORD_RESET_INVALID'
    with pg_env[0]() as session:
        assert PasswordHasher().verify(session.get(User, 'alice').password_hash, 'old-password-123')
        assert session.scalar(select(SecurityHold)) is None


def test_verify_sql_lock_wait_respects_remaining_deadline(pg_env):
    api = service(pg_env)
    api.request_password_code(channel='email', target='alice@example.test')
    code = email_code(pg_env, 'password_reset_email')
    with pg_env[0].begin() as lock:
        lock.scalar(select(User).where(User.id == 'alice').with_for_update())
        start = time.monotonic()
        with ThreadPoolExecutor(max_workers=1) as pool:
            result = pool.submit(attempt, lambda: api.verify_password_code(channel='email', target='alice@example.test',
                code=code, deadline=start + .2)).result(timeout=1)
        assert result == 'PASSWORD_RESET_INVALID'
        assert time.monotonic() - start < 1
    with pg_env[0]() as session:
        otp = session.scalar(select(OtpChallenge).where(OtpChallenge.purpose == 'password_reset_email'))
        assert otp.consumed_at is None and otp.attempts_left == 5
        assert session.scalar(select(OtpChallenge).where(OtpChallenge.purpose == 'password_reset_grant')) is None


def test_parallel_otp_verify_and_grant_reset_each_have_one_winner(pg_env):
    api = service(pg_env)
    api.request_password_code(channel='email', target='alice@example.test')
    code = email_code(pg_env, 'password_reset_email')
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda _: attempt(lambda: api.verify_password_code(channel='email', target='alice@example.test', code=code)), range(8)))
    proofs = [value for value in results if isinstance(value, dict)]
    assert len(proofs) == 1 and results.count('PASSWORD_RESET_INVALID') == 7
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda _: attempt(lambda: api.reset_password(token=proofs[0]['reset_token'], new_password='new-password-123')), range(8)))
    assert results.count(None) == 1 and results.count('PASSWORD_RESET_INVALID') == 7
    with pg_env[0]() as session:
        assert len(session.scalars(select(SecurityHold)).all()) == 1
        assert len(session.scalars(select(AuditEvent)).all()) == 1


def test_parallel_two_owners_claiming_same_email_has_one_winner(pg_env):
    api = service(pg_env)
    codes = {}
    for owner in ('alice', 'bob'):
        api.request_old_email_channel(user_id=owner)
        with pg_env[0]() as session:
            row = session.scalar(select(OtpChallenge).where(OtpChallenge.user_id == owner, OtpChallenge.purpose == 'email_bind_old_email'))
        api.confirm_old_email_channel(user_id=owner, code=deliver_email_challenge(pg_env, row))
        api.request_new_email(user_id=owner, email='shared@example.test')
        with pg_env[0]() as session:
            row = session.scalar(select(OtpChallenge).where(OtpChallenge.user_id == owner, OtpChallenge.purpose == 'email_bind_new'))
        codes[owner] = deliver_email_challenge(pg_env, row)
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda owner: attempt(lambda: api.confirm_new_email(user_id=owner, new_email='shared@example.test', code=codes[owner])), ('alice', 'bob')))
    assert sum(isinstance(result, dict) for result in results) == 1
    assert results.count('EMAIL_TAKEN') == 1
    with pg_env[0]() as session:
        assert len(session.scalars(select(User).where(User.email_normalized == 'shared@example.test')).all()) == 1


def test_parallel_verify_and_reset_do_not_deadlock_or_reactivate_old_proof(pg_env):
    api = service(pg_env)
    api.request_password_code(channel='phone', target='13800000001')
    proof = api.verify_password_code(channel='phone', target='13800000001', code=deliver_phone(pg_env))
    api.request_password_code(channel='email', target='alice@example.test')
    code = email_code(pg_env, 'password_reset_email')
    def run(index):
        if index % 2:
            return attempt(lambda: api.verify_password_code(channel='email', target='alice@example.test', code=code))
        return attempt(lambda: api.reset_password(token=proof['reset_token'], new_password='new-password-123'))
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(run, range(8)))
    assert sum(value is None or isinstance(value, dict) for value in results) == 1


def test_parallel_worker_delivery_and_send_quota_are_single_reservation(pg_env):
    api = service(pg_env)
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(lambda _: api.request_password_code(channel='phone', target='13800000001'), range(8)))
    with pg_env[0]() as session:
        rows = session.scalars(select(OtpChallenge).where(OtpChallenge.purpose == 'password_reset_phone')).all()
        assert len(rows) == 3
        pending = [row for row in rows if row.invalidated_at is None]
        assert len(pending) == 1
        challenge_id = pending[0].id
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(lambda _: pg_env[1].deliver_password_phone(challenge_id, code_deriver=pg_env[2].verification_code), range(8)))
    assert len(pg_env[4].messages) == 1


def test_parallel_email_worker_replay_sends_once_and_activates_once(pg_env):
    from app.core.outbox import OutboxEvent, OutboxMessage
    from tasks.identity import IdentityEmailVerificationTask
    api = service(pg_env)
    api.request_password_code(channel='email', target='alice@example.test')
    with pg_env[0]() as session:
        event = session.scalar(select(OutboxEvent))
        message = OutboxMessage(event.id, event.topic, event.event_type, event.aggregate_type, event.aggregate_id, event.payload, {}, 1)
    class Sender:
        def __init__(self): self.messages = []
        def send_email_otp(self, **kwargs): self.messages.append(kwargs)
    sender = Sender()
    task = IdentityEmailVerificationTask(pg_env[0], token_codec=pg_env[2], public_base_url='https://example.test',
        email_sender=sender, now_factory=lambda: pg_env[5][0])
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(lambda _: task(message), range(8)))
    assert len(sender.messages) == 1
    api.verify_password_code(channel='email', target='alice@example.test', code=sender.messages[0]['code'])
