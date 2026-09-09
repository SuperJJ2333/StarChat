from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import create_engine, select, func

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.core.outbox import OutboxEvent
from app.modules.audit.models import AuditEvent
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User, Device, RefreshTokenFamily, TotpCredential
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.totp import FernetSecretProtector, TotpService


@pytest.fixture
def setup():
    from app.modules.identity.wallet_mfa import WalletMfaService
    engine = create_engine('sqlite+pysqlite:///:memory:')
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    hasher = PasswordHasher()
    with factory.begin() as session:
        session.add(User(id='user', username='user', username_normalized='user', email='u@example.test',
            email_normalized='u@example.test', password_hash=hasher.hash('test-password-only'),
            status=AccountStatus.ACTIVE, created_at=now, updated_at=now))
        session.add(Device(id='device', user_id='user', device_key='test', display_name='test',
            last_seen_at=now, created_at=now))
        session.add(RefreshTokenFamily(id='family', user_id='user', device_id='device', created_at=now))
    class Limiter:
        calls = 0
        def hit(self, *args, **kwargs):
            self.calls += 1
    limiter = Limiter()
    protector = FernetSecretProtector.generate()
    service = WalletMfaService(factory, protector=protector, password_hasher=hasher,
        rate_limiter=limiter, clock=lambda: now)
    yield service, factory, now, protector, limiter
    engine.dispose()


def begin(service):
    return service.begin(user_id='user', session_id='family', password='test-password-only')


def test_pending_status_allows_recovery_without_disclosing_secret(setup):
    service, factory, now, protector, limiter = setup
    totp = TotpService(factory, protector=protector)
    assert totp.status('user')['pending_credential_id'] is None
    enrollment = begin(service)
    status = totp.status('user')
    assert status['pending_credential_id'] == enrollment['credential_id']
    assert enrollment['secret'] not in str(status)
    assert totp.status('another-user')['pending_credential_id'] is None
    with factory.begin() as session:
        session.get(TotpCredential, enrollment['credential_id']).enabled = True
    assert totp.status('user')['pending_credential_id'] is None


def test_enroll_enable_encrypted_audited_and_code_consumed(setup):
    service, factory, now, protector, limiter = setup
    result = begin(service)
    with factory() as session:
        credential = session.get(TotpCredential, result['credential_id'])
        assert credential.encrypted_secret != result['secret']
        assert protector.decrypt(credential.encrypted_secret) == result['secret']
        assert not credential.enabled
    code = TotpService.code_at(result['secret'], now)
    service.enable(user_id='user', session_id='family', credential_id=result['credential_id'], code=code)
    totp = TotpService(factory, protector=protector, now_factory=lambda: now)
    with pytest.raises(AppError) as error:
        totp.verify('user', code)
    assert error.value.code == 'TOTP_REPLAYED'
    with factory() as session:
        audits = session.scalars(select(AuditEvent)).all()
        events = session.scalars(select(OutboxEvent)).all()
        assert len(audits) == len(events) == 2
        assert result['secret'] not in str([a.after_data for a in audits]) + str([e.payload for e in events])
    assert limiter.calls == 2


@pytest.mark.parametrize('mutation', ['missing_family', 'revoked_family', 'revoked_device', 'other_user', 'future_login'])
def test_actual_recent_session_required(setup, mutation):
    service, factory, now, _, _ = setup
    with factory.begin() as session:
        family = session.get(RefreshTokenFamily, 'family')
        if mutation == 'missing_family': session.delete(family)
        elif mutation == 'revoked_family': family.revoked_at = now
        elif mutation == 'revoked_device': session.get(Device, 'device').revoked_at = now
        elif mutation == 'other_user': family.user_id = 'someone-else'
        elif mutation == 'old_login': family.created_at = now-timedelta(minutes=6)
        elif mutation == 'future_login': family.created_at = now+timedelta(seconds=1)
    with pytest.raises(AppError): begin(service)
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(TotpCredential)) == 0


def test_password_required(setup):
    service, factory, *_ = setup
    with pytest.raises(AppError):
        service.begin(user_id='user', session_id='family', password='wrong')
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(TotpCredential)) == 0


def test_old_login_can_setup_with_password_and_scoped_proof(setup):
    service, factory, now, *_ = setup
    with factory.begin() as db:
        db.get(RefreshTokenFamily, 'family').created_at = now-timedelta(days=1)
    result = begin(service)
    assert result['setup_proof']
    code = TotpService.code_at(result['secret'], now)
    assert service.enable(user_id='user', session_id='family',
        credential_id=result['credential_id'], code=code,
        setup_proof=result['setup_proof']) == {'enabled': True}


@pytest.mark.parametrize('mutation', ['expired', 'tampered', 'revoked_device', 'password_changed'])
def test_setup_proof_rejects_invalid_context(setup, mutation):
    service, factory, now, *_ = setup
    result = begin(service)
    proof = result['setup_proof']
    if mutation == 'expired': service.clock = lambda: now+timedelta(seconds=301)
    elif mutation == 'tampered': proof = 'invalid'
    else:
        with factory.begin() as db:
            if mutation == 'revoked_device': db.get(Device, 'device').revoked_at = now
            else: db.get(User, 'user').password_hash = 'changed'
    with pytest.raises(AppError):
        service.enable(user_id='user', session_id='family',
            credential_id=result['credential_id'], code=TotpService.code_at(result['secret'], service.clock()),
            setup_proof=proof)
    with factory() as db:
        assert not db.get(TotpCredential, result['credential_id']).enabled


def test_proof_is_scoped_to_family_and_pending_credential(setup):
    service, factory, now, *_ = setup
    result = begin(service)
    with factory.begin() as db:
        db.add(RefreshTokenFamily(id='other-family', user_id='user', device_id='device', created_at=now))
    with pytest.raises(AppError):
        service.enable(user_id='user', session_id='other-family', credential_id=result['credential_id'],
            code=TotpService.code_at(result['secret'], now), setup_proof=result['setup_proof'])
    with factory.begin() as db:
        db.get(RefreshTokenFamily, 'family').created_at = now-timedelta(days=1)
    renewed = service.reauthenticate(user_id='user', session_id='family',
        credential_id=result['credential_id'], password='test-password-only')
    service.enable(user_id='user', session_id='family', credential_id=result['credential_id'],
        code=TotpService.code_at(result['secret'], now), setup_proof=renewed['setup_proof'])
    with pytest.raises(AppError):
        service.enable(user_id='user', session_id='family', credential_id=result['credential_id'],
            code=TotpService.code_at(result['secret'], now), setup_proof=renewed['setup_proof'])


def test_begin_never_overwrites_pending_or_enabled(setup):
    service, factory, now, *_ = setup
    result = begin(service)
    with pytest.raises(AppError): begin(service)
    service.enable(user_id='user', session_id='family', credential_id=result['credential_id'],
        code=TotpService.code_at(result['secret'], now))
    with pytest.raises(AppError): begin(service)
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(TotpCredential)) == 1
        assert session.get(TotpCredential, result['credential_id']).enabled


@pytest.mark.parametrize('code', ['wrong', '１２３４５６', '12345', '0000000'])
def test_invalid_enable_preserves_pending(setup, code):
    service, factory, *_ = setup
    result = begin(service)
    with pytest.raises(AppError):
        service.enable(user_id='user', session_id='family', credential_id=result['credential_id'], code=code)
    with factory() as session:
        assert not session.get(TotpCredential, result['credential_id']).enabled


def test_pending_abort_requires_password_and_cannot_disable_enabled(setup):
    service, factory, now, *_ = setup
    result = begin(service)
    with pytest.raises(AppError):
        service.abort_pending(user_id='user', session_id='family', credential_id=result['credential_id'], password='wrong')
    service.abort_pending(user_id='user', session_id='family', credential_id=result['credential_id'], password='test-password-only')
    replacement = begin(service)
    assert replacement['credential_id'] != result['credential_id']
    with pytest.raises(AppError):
        service.enable(user_id='user', session_id='family', credential_id=result['credential_id'], code=TotpService.code_at(result['secret'], now))
    service.enable(user_id='user', session_id='family', credential_id=replacement['credential_id'], code=TotpService.code_at(replacement['secret'], now))
    with pytest.raises(AppError):
        service.abort_pending(user_id='user', session_id='family', credential_id=replacement['credential_id'], password='test-password-only')


def test_audit_failure_rolls_back_enrollment(setup, monkeypatch):
    service, factory, *_ = setup
    from app.core.outbox import OutboxPublisher
    def failure(*args, **kwargs): raise RuntimeError('audit-outbox-failure')
    monkeypatch.setattr(OutboxPublisher, 'enqueue', failure)
    with pytest.raises(RuntimeError): begin(service)
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(TotpCredential)) == 0
        assert session.scalar(select(func.count()).select_from(AuditEvent)) == 0


@pytest.mark.parametrize('credential_id', [None, '', ' '*36, 'x'*37])
def test_enable_abort_require_explicit_credential_id(setup, credential_id):
    service, factory, now, *_ = setup
    result = begin(service)
    with pytest.raises(AppError):
        service.enable(user_id='user', session_id='family', credential_id=credential_id,
            code=TotpService.code_at(result['secret'], now))
    with pytest.raises(AppError):
        service.abort_pending(user_id='user', session_id='family', credential_id=credential_id,
            password='test-password-only')
    with factory() as session:
        assert not session.get(TotpCredential, result['credential_id']).enabled
        assert session.scalar(select(func.count()).select_from(AuditEvent)) == 1


@pytest.mark.parametrize('fault', ['revoked_family', 'revoked_device', 'other_user', 'wrong_id', 'rate_limit'])
def test_keyless_abort_retains_authorization_and_rate_limit(setup, fault):
    service, factory, now, _, limiter = setup
    enrollment = begin(service)
    service.protector = None
    with factory.begin() as session:
        family = session.get(RefreshTokenFamily, 'family')
        if fault == 'old_login': family.created_at = now-timedelta(minutes=6)
        elif fault == 'revoked_family': family.revoked_at = now
        elif fault == 'revoked_device': session.get(Device, 'device').revoked_at = now
        elif fault == 'other_user': family.user_id = 'another-user'
    if fault == 'rate_limit':
        def limited(*args, **kwargs):
            raise AppError(code='RATE_LIMITED', message='rate limited', status_code=429)
        limiter.hit = limited
    with pytest.raises(AppError):
        service.abort_pending(user_id='user', session_id='family',
            credential_id='other' if fault == 'wrong_id' else enrollment['credential_id'], password='test-password-only')
    with factory() as session:
        assert session.get(TotpCredential, enrollment['credential_id']) is not None
        assert session.scalar(select(func.count()).select_from(AuditEvent)) == 1


def test_keyless_service_guards_crypto_and_audits_abort_atomically(setup, monkeypatch):
    service, factory, _, _, limiter = setup
    enrollment = begin(service)
    service.protector = None
    for action in (lambda: begin(service), lambda: service.enable(user_id='user', session_id='family',
            credential_id=enrollment['credential_id'], code='123456')):
        with pytest.raises(AppError, match='动态验证配置尚未就绪') as failure:
            action()
        assert failure.value.status_code == 503
    original = service._record
    def fail(*args, **kwargs):
        raise RuntimeError('audit unavailable')
    monkeypatch.setattr(service, '_record', fail)
    arguments = dict(user_id='user', session_id='family', credential_id=enrollment['credential_id'], password='test-password-only')
    with pytest.raises(RuntimeError): service.abort_pending(**arguments)
    with factory() as session:
        assert session.get(TotpCredential, enrollment['credential_id']) is not None
    monkeypatch.setattr(service, '_record', original)
    assert service.abort_pending(**arguments) == {'enabled': False}
    assert limiter.calls == 3
    with factory() as session:
        assert session.get(TotpCredential, enrollment['credential_id']) is None
        assert session.scalar(select(func.count()).select_from(AuditEvent).where(
            AuditEvent.action == 'identity.totp.pending_aborted')) == 1
        events = list(session.scalars(select(OutboxEvent).where(OutboxEvent.event_type == 'identity.totp.pending_aborted')))
        assert len(events) == 1
        assert enrollment['secret'] not in str(events[0].payload)
