"""ADR-0085: verified contact proofs, atomic recovery and email binding."""
from datetime import datetime, timedelta, timezone
import importlib.util

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker

from app.core.database import Base
from app.core.errors import AppError
from app.core.outbox import OutboxEvent, OutboxPublisher, OutboxMessage
import app.modules.audit.models
from app.modules.audit.models import AuditEvent
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import OtpChallenge, User, SecurityHold, RefreshTokenFamily
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.phone import PhoneOtpService, RecordingSmsSender
from app.modules.identity.phone import PhoneAuthService
from app.modules.identity.recovery import PasswordRecoveryService, PasswordResetTokenCodec
from app.modules.identity.registration import VerificationTokenCodec


@pytest.fixture
def env(tmp_path):
    engine = create_engine(f"sqlite+pysqlite:///{tmp_path / 'credentials.db'}")
    Base.metadata.create_all(engine)
    factory = sessionmaker(engine, expire_on_commit=False)
    clock = [datetime(2026, 9, 26, tzinfo=timezone.utc)]
    now = lambda: clock[0]
    hasher = PasswordHasher()
    with factory.begin() as session:
        for name in ('alice', 'bob'):
            session.add(User(id=name, username=name, username_normalized=name,
                email=f'{name}@example.test', email_normalized=f'{name}@example.test',
                email_verified_at=now(), phone='+8613800000001' if name == 'alice' else '+8613800000002',
                phone_normalized='+8613800000001' if name == 'alice' else '+8613800000002',
                phone_verified_at=now(), password_hash=hasher.hash('old-password-123'),
                status=AccountStatus.ACTIVE, matrix_user_id=f'@{name}:test', created_at=now(), updated_at=now()))
    sender = RecordingSmsSender()
    otp = PhoneOtpService(factory, sender=sender, secret='test-otp-secret', now=now)
    codec = VerificationTokenCodec(b'test-email-code-secret')
    recovery = PasswordRecoveryService(factory, password_hasher=hasher,
        token_codec=PasswordResetTokenCodec(b'test-reset-secret'), now_factory=now)
    yield factory, otp, codec, recovery, sender, clock
    engine.dispose()


def service(env):
    assert importlib.util.find_spec('app.modules.identity.account_credentials') is not None, 'ADR-0085 service missing'
    from app.modules.identity.account_credentials import AccountCredentialsService
    factory, otp, codec, recovery, sender, clock = env
    return AccountCredentialsService(factory, otp=otp, recovery=recovery,
        email_code_deriver=codec.verification_code, now_factory=lambda: clock[0])


def email_code(env, purpose):
    factory, otp, codec, *_ = env
    with factory() as session:
        row = session.scalar(select(OtpChallenge).where(OtpChallenge.purpose == purpose, OtpChallenge.invalidated_at.is_(None)).order_by(OtpChallenge.created_at.desc()))
    return deliver_email_challenge(env, row)


def deliver_email_challenge(env, row):
    from tasks.identity import IdentityEmailVerificationTask
    with env[0]() as session:
        event = session.scalar(select(OutboxEvent).where(OutboxEvent.aggregate_id == row.id))
    class Sender:
        def send_email_otp(self, **kwargs):
            pass
    task = IdentityEmailVerificationTask(env[0], token_codec=env[2], public_base_url='https://example.test',
        email_sender=Sender(), now_factory=lambda: env[5][0])
    task(OutboxMessage(event.id, event.topic, event.event_type, event.aggregate_type, event.aggregate_id, event.payload, {}, 1))
    return env[2].verification_code(row.id)


def deliver_phone(env):
    with env[0]() as session:
        challenge = session.scalar(select(OtpChallenge).where(OtpChallenge.purpose == 'password_reset_phone',
            OtpChallenge.invalidated_at.is_(None), OtpChallenge.consumed_at.is_(None)))
    env[1].deliver_password_phone(challenge.id, code_deriver=env[2].verification_code)
    return env[1].sender.messages[-1][1]


@pytest.mark.parametrize('result', [True, False, 'exception'])
def test_late_provider_result_rolls_back_attempt_and_grant(env, monkeypatch, result):
    import app.modules.identity.phone as phone_module
    api = service(env)
    api.request_password_code(channel='phone', target='13800000001')
    code = deliver_phone(env)
    tick = [100.0]
    monkeypatch.setattr(phone_module.time, 'monotonic', lambda: tick[0])
    def provider(*args):
        tick[0] = 105.0
        if result == 'exception':
            raise RuntimeError('provider unavailable')
        return result
    env[1].code_verifier = provider
    with pytest.raises(AppError) as error:
        api.verify_password_code(channel='phone', target='13800000001', code=code, deadline=104.5)
    assert error.value.code == 'PASSWORD_RESET_INVALID'
    with env[0]() as session:
        otp = session.scalar(select(OtpChallenge).where(OtpChallenge.purpose == 'password_reset_phone'))
        assert otp.attempts_left == 5 and otp.consumed_at is None
        assert session.scalar(select(OtpChallenge).where(OtpChallenge.purpose == 'password_reset_grant')) is None


@pytest.mark.parametrize('matched', [True, False])
def test_provider_crossing_utc_expiry_cannot_consume_or_decrement(env, matched):
    api = service(env)
    api.request_password_code(channel='phone', target='13800000001')
    code = deliver_phone(env)
    env[5][0] += timedelta(seconds=899)
    def provider(*args):
        env[5][0] += timedelta(seconds=2)
        return matched
    env[1].code_verifier = provider
    with pytest.raises(AppError):
        api.verify_password_code(channel='phone', target='13800000001', code=code)
    with env[0]() as session:
        otp = session.scalar(select(OtpChallenge).where(OtpChallenge.purpose == 'password_reset_phone'))
        assert otp.attempts_left == 5 and otp.consumed_at is None
        assert session.scalar(select(OtpChallenge).where(OtpChallenge.purpose == 'password_reset_grant')) is None


def test_old_email_proof_gets_full_five_minutes_after_success(env):
    api = service(env)
    api.request_old_email_channel(user_id='alice')
    code = email_code(env, 'email_bind_old_email')
    env[5][0] += timedelta(seconds=299)
    api.confirm_old_email_channel(user_id='alice', code=code)
    env[5][0] += timedelta(seconds=101)
    assert api.request_new_email(user_id='alice', email='new@example.test')['accepted']
    env[5][0] += timedelta(seconds=200)
    with pytest.raises(AppError) as error:
        api.request_new_email(user_id='alice', email='new@example.test')
    assert error.value.code == 'REBIND_OLD_VERIFICATION_REQUIRED'


@pytest.mark.parametrize('channel,target', [('email', ' ALICE@example.test '), ('phone', '13800000001')])
def test_two_step_recovery_single_use_and_security_effects(env, channel, target):
    api = service(env)
    assert api.request_password_code(channel=channel, target=target) == {'accepted': True, 'resend_after_seconds': 60}
    code = email_code(env, 'password_reset_email') if channel == 'email' else deliver_phone(env)
    proof = api.verify_password_code(channel=channel, target=target, code=code)
    assert proof['expires_in'] == 300
    with env[0]() as session:
        assert PasswordHasher().verify(session.get(User, 'alice').password_hash, 'old-password-123')
    api.reset_password(token=proof['reset_token'], new_password='new-password-123')
    with env[0]() as session:
        assert PasswordHasher().verify(session.get(User, 'alice').password_hash, 'new-password-123')
        assert session.scalar(select(SecurityHold)).reason_code == 'PASSWORD_RESET'
        assert session.scalar(select(AuditEvent)).action == 'identity.password.reset'
        assert session.scalar(select(OutboxEvent).where(OutboxEvent.event_type == 'identity.password.reset'))
    with pytest.raises(AppError):
        api.reset_password(token=proof['reset_token'], new_password='again-password-123')
    with pytest.raises(AppError):
        api.verify_password_code(channel=channel, target=target, code=code)


@pytest.mark.parametrize('change', ['email_unverified', 'phone_unverified', 'inactive', 'unknown', 'other_user'])
def test_no_recovery_otp_for_ineligible_contact(env, change):
    api = service(env)
    channel, target, user_id = 'email', 'alice@example.test', None
    with env[0].begin() as session:
        user = session.get(User, 'alice')
        if change == 'email_unverified': user.email_verified_at = None
        elif change == 'phone_unverified':
            user.phone_verified_at = None
            channel, target = 'phone', '13800000001'
        elif change == 'inactive': user.status = AccountStatus.PENDING_MATRIX
        elif change == 'unknown': target = 'nobody@example.test'
        elif change == 'other_user': user_id = 'bob'
    assert api.request_password_code(channel=channel, target=target, user_id=user_id)['accepted']
    with env[0]() as session:
        assert session.scalar(select(OtpChallenge)) is None


def test_email_codes_never_use_sms_and_five_wrong_attempts_lock(env):
    api = service(env)
    env[1].phone_enabled = False
    env[1].code_verifier = lambda *args: pytest.fail('email reached SMS provider')
    api.request_password_code(channel='email', target='alice@example.test')
    code = email_code(env, 'password_reset_email')
    for _ in range(5):
        with pytest.raises(AppError):
            api.verify_password_code(channel='email', target='alice@example.test', code='000000' if code != '000000' else '111111')
    with pytest.raises(AppError):
        api.verify_password_code(channel='email', target='alice@example.test', code=code)


def test_proof_rechecks_binding_status_owner_and_expiry(env):
    api = service(env)
    api.request_password_code(channel='email', target='alice@example.test')
    proof = api.verify_password_code(channel='email', target='alice@example.test', code=email_code(env, 'password_reset_email'))
    with pytest.raises(AppError):
        api.reset_password(token=proof['reset_token'], new_password='new-password-123', user_id='bob')
    with env[0].begin() as session:
        session.get(User, 'alice').email_normalized = 'changed@example.test'
    with pytest.raises(AppError):
        api.reset_password(token=proof['reset_token'], new_password='new-password-123')


def test_email_binding_requires_old_proof_then_new_proof_and_invalidates_recovery(env):
    api = service(env)
    old_link = env[3].request('alice@example.test')
    api.request_password_code(channel='email', target='alice@example.test')
    grant = api.verify_password_code(channel='email', target='alice@example.test', code=email_code(env, 'password_reset_email'))
    with pytest.raises(AppError):
        api.request_new_email(user_id='alice', email='new@example.test')
    assert api.request_old_email_channel(user_id='alice')['channel'] == 'email'
    api.confirm_old_email_channel(user_id='alice', code=email_code(env, 'email_bind_old_email'))
    api.request_new_email(user_id='alice', email='NEW@example.test')
    result = api.confirm_new_email(user_id='alice', new_email='new@example.test', code=email_code(env, 'email_bind_new'))
    assert result['verified'] and result['email'] != 'new@example.test'
    with env[0]() as session:
        assert session.get(User, 'alice').email_normalized == 'new@example.test'
        assert session.get(User, 'alice').email_verified_at is not None
    with pytest.raises(AppError): api.reset_password(token=grant['reset_token'], new_password='new-password-123')
    with pytest.raises(AppError): env[3].reset(old_link, 'new-password-123')
    with pytest.raises(AppError): api.request_new_email(user_id='alice', email='again@example.test')


def test_first_email_binding_uses_verified_phone_and_conflict_does_not_mutate(env):
    api = service(env)
    with env[0].begin() as session:
        user = session.get(User, 'alice')
        user.email = user.email_normalized = user.email_verified_at = None
    assert api.request_old_email_channel(user_id='alice')['channel'] == 'phone'
    api.confirm_old_email_channel(user_id='alice', code=env[4].messages[-1][1])
    with pytest.raises(AppError): api.request_new_email(user_id='alice', email='bob@example.test')
    api.request_new_email(user_id='alice', email='new@example.test')
    api.confirm_new_email(user_id='alice', new_email='new@example.test', code=email_code(env, 'email_bind_new'))
    assert api.summary('alice')['email_verified']


def test_email_send_limit_and_password_policy(env):
    api = service(env)
    for _ in range(3): api.request_password_code(channel='email', target='alice@example.test', user_id='alice')
    with pytest.raises(AppError) as error: api.request_password_code(channel='email', target='alice@example.test', user_id='alice')
    assert error.value.status_code == 429
    proof = api.verify_password_code(channel='email', target='alice@example.test', code=email_code(env, 'password_reset_email'))
    for password in ('short', 'x' * 257):
        with pytest.raises(AppError) as error: api.reset_password(token=proof['reset_token'], new_password=password)
        assert error.value.status_code == 422
    api.reset_password(token=proof['reset_token'], new_password='new-password-123')


@pytest.mark.parametrize('stage', ['otp', 'grant', 'old_binding'])
def test_expired_proof_cannot_advance(env, stage):
    api = service(env)
    if stage == 'old_binding':
        api.request_old_email_channel(user_id='alice')
        api.confirm_old_email_channel(user_id='alice', code=email_code(env, 'email_bind_old_email'))
        env[5][0] += timedelta(minutes=6)
        with pytest.raises(AppError): api.request_new_email(user_id='alice', email='new@example.test')
        return
    api.request_password_code(channel='email', target='alice@example.test')
    code = email_code(env, 'password_reset_email')
    if stage == 'grant':
        proof = api.verify_password_code(channel='email', target='alice@example.test', code=code)
    env[5][0] += timedelta(minutes=6)
    with pytest.raises(AppError):
        if stage == 'otp': api.verify_password_code(channel='email', target='alice@example.test', code=code)
        else: api.reset_password(token=proof['reset_token'], new_password='new-password-123')


def test_changed_verification_epoch_rejects_same_target_otp_and_grant(env):
    api = service(env)
    api.request_password_code(channel='email', target='alice@example.test')
    code = email_code(env, 'password_reset_email')
    with env[0].begin() as session:
        session.get(User, 'alice').email_verified_at += timedelta(seconds=1)
    with pytest.raises(AppError): api.verify_password_code(channel='email', target='alice@example.test', code=code)
    api.request_password_code(channel='phone', target='13800000001')
    proof = api.verify_password_code(channel='phone', target='13800000001', code=deliver_phone(env))
    with env[0].begin() as session:
        session.get(User, 'alice').phone_verified_at += timedelta(seconds=1)
    with pytest.raises(AppError): api.reset_password(token=proof['reset_token'], new_password='new-password-123')


def test_provider_failure_does_not_consume_attempts_or_disclose_target(env):
    api = service(env)
    def broken(*args): raise AppError(code='SMS_PROVIDER_UNAVAILABLE', message='service unavailable', status_code=503)
    env[1].sender.send_challenge = broken
    known = api.request_password_code(channel='phone', target='13800000001')
    unknown = api.request_password_code(channel='phone', target='13900000000')
    assert known == unknown
    with pytest.raises(AppError): deliver_phone(env)
    with env[0]() as session:
        row = session.scalar(select(OtpChallenge))
        assert row.invalidated_at and row.attempts_left == 0
    env[1].sender = RecordingSmsSender()
    api.request_password_code(channel='phone', target='13800000001')
    code = deliver_phone(env)
    env[1].code_verifier = broken
    with pytest.raises(AppError): api.verify_password_code(channel='phone', target='13800000001', code=code)
    with env[0]() as session:
        row = session.scalar(select(OtpChallenge).where(OtpChallenge.invalidated_at.is_(None)))
        assert row.attempts_left == 5 and row.consumed_at is None


def test_phone_rebind_invalidates_email_grants_and_link_proofs(env):
    api = service(env)
    api.request_password_code(channel='email', target='alice@example.test')
    proof = api.verify_password_code(channel='email', target='alice@example.test', code=email_code(env, 'password_reset_email'))
    phone = PhoneAuthService(env[0], otp=env[1], now=lambda: env[5][0])
    phone.request_old_channel_verification(user_id='alice')
    phone.confirm_old_channel(user_id='alice', code=env[4].messages[-1][1])
    phone.request_new_phone_verification(user_id='alice', new_phone='13900000000')
    phone.confirm_new_phone(user_id='alice', new_phone='13900000000', code=env[4].messages[-1][1])
    with pytest.raises(AppError): api.reset_password(token=proof['reset_token'], new_password='new-password-123')
    with env[0]() as session:
        assert session.scalar(select(AuditEvent).where(AuditEvent.action == 'identity.phone.bound')) is not None
        assert session.scalar(select(OutboxEvent).where(OutboxEvent.event_type == 'identity.phone.bound')) is not None


def test_reset_revokes_all_business_refresh_families_and_rollback_is_atomic(env, monkeypatch):
    from app.modules.identity.tokens import TokenService
    api = service(env)
    pair = TokenService(env[0], jwt_secret='test-jwt-secret-at-least-thirty-two-bytes', jwt_issuer='test', now_factory=lambda: env[5][0]).issue_pair(user_id='alice', device_key='device', display_name='test')
    api.request_password_code(channel='email', target='alice@example.test')
    proof = api.verify_password_code(channel='email', target='alice@example.test', code=email_code(env, 'password_reset_email'))
    original = OutboxPublisher.enqueue
    def fail(*args, **kwargs): raise RuntimeError('test queue failure')
    monkeypatch.setattr(OutboxPublisher, 'enqueue', fail)
    with pytest.raises(RuntimeError): api.reset_password(token=proof['reset_token'], new_password='new-password-123')
    with env[0]() as session:
        assert session.get(RefreshTokenFamily, pair.family_id).revoked_at is None
        assert session.scalar(select(SecurityHold)) is None
        assert PasswordHasher().verify(session.get(User, 'alice').password_hash, 'old-password-123')
    monkeypatch.setattr(OutboxPublisher, 'enqueue', original)
    api.reset_password(token=proof['reset_token'], new_password='new-password-123')
    with env[0]() as session:
        assert session.get(RefreshTokenFamily, pair.family_id).revoke_reason == 'PASSWORD_RESET'


def test_new_email_challenges_are_bound_to_owner_when_same_target_requested(env):
    api = service(env)
    for user_id in ('alice', 'bob'):
        api.request_old_email_channel(user_id=user_id)
        with env[0]() as session:
            challenge = session.scalar(select(OtpChallenge).where(OtpChallenge.user_id == user_id,
                OtpChallenge.purpose == 'email_bind_old_email', OtpChallenge.invalidated_at.is_(None)))
        api.confirm_old_email_channel(user_id=user_id, code=deliver_email_challenge(env, challenge))
        api.request_new_email(user_id=user_id, email='shared@example.test')
    with env[0]() as session:
        rows = session.scalars(select(OtpChallenge).where(OtpChallenge.purpose == 'email_bind_new',
            OtpChallenge.invalidated_at.is_(None))).all()
        assert len(rows) == 2
        first = next(row for row in rows if row.user_id == 'alice')
    api.confirm_new_email(user_id='alice', new_email='shared@example.test', code=deliver_email_challenge(env, first))
    with env[0]() as session:
        assert session.get(User, 'alice').email_normalized == 'shared@example.test'
        assert session.get(User, 'bob').email_normalized == 'bob@example.test'


def test_password_phone_request_queues_without_calling_provider(env):
    api = service(env)
    api.request_password_code(channel='phone', target='13800000001')
    assert env[4].messages == []
    with env[0]() as session:
        challenge = session.scalar(select(OtpChallenge))
        assert challenge.attempts_left == 0
        assert session.scalar(select(OutboxEvent)).topic == 'identity.password_phone'


def test_new_email_challenge_is_pending_until_worker_delivery(env):
    api = service(env)
    api.request_password_code(channel='email', target='alice@example.test')
    with env[0]() as session:
        row = session.scalar(select(OtpChallenge))
        assert row.attempts_left == 0
        code = env[2].verification_code(row.id)
    with pytest.raises(AppError): api.verify_password_code(channel='email', target='alice@example.test', code=code)


def test_pending_phone_proof_and_exhausted_proof_never_reactivate_on_worker_retry(env):
    api = service(env)
    api.request_password_code(channel='phone', target='13800000001')
    with env[0]() as session:
        pending = session.scalar(select(OtpChallenge).where(OtpChallenge.purpose == 'password_reset_phone'))
    code = env[2].verification_code(pending.id)
    with pytest.raises(AppError): api.verify_password_code(channel='phone', target='13800000001', code=code)
    assert deliver_phone(env) == code
    for _ in range(5):
        with pytest.raises(AppError): api.verify_password_code(channel='phone', target='13800000001', code='111111' if code != '111111' else '222222')
    with env[0]() as session:
        row = session.scalar(select(OtpChallenge).where(OtpChallenge.purpose == 'password_reset_phone'))
    env[1].deliver_password_phone(row.id, code_deriver=env[2].verification_code)
    assert len(env[4].messages) == 1
    with pytest.raises(AppError): api.verify_password_code(channel='phone', target='13800000001', code=code)


@pytest.mark.parametrize('change_stage', ['before_send', 'during_send'])
def test_phone_delivery_rechecks_contact_snapshot_before_and_after_provider(env, change_stage):
    api = service(env)
    api.request_password_code(channel='phone', target='13800000001')
    def change_binding():
        with env[0].begin() as session:
            session.get(User, 'alice').phone_verified_at += timedelta(seconds=1)
    if change_stage == 'before_send':
        change_binding()
    else:
        original = env[4].send_challenge
        def delayed(*args):
            original(*args)
            change_binding()
        env[4].send_challenge = delayed
    with env[0]() as session:
        row = session.scalar(select(OtpChallenge).where(OtpChallenge.purpose == 'password_reset_phone'))
    env[1].deliver_password_phone(row.id, code_deriver=env[2].verification_code)
    assert len(env[4].messages) == (0 if change_stage == 'before_send' else 1)
    with pytest.raises(AppError): api.verify_password_code(channel='phone', target='13800000001', code=env[2].verification_code(row.id))
