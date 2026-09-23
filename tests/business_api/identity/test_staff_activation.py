from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import create_engine, delete, select

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.modules.identity.enums import AccountStatus, RoleCode
from app.modules.identity.models import User, UserRole, OtpChallenge
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.phone import PhoneOtpService, RecordingSmsSender


@pytest.fixture
def env(tmp_path):
    import app.main  # Register application model metadata before schema creation.
    # Import at runtime so RED reports the missing feature in a test body.
    from app.modules.identity.staff_activation import StaffActivationService
    engine = create_engine(f'sqlite:///{tmp_path / "activation.db"}')
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    clock = [datetime.now(timezone.utc)]
    sender = RecordingSmsSender()
    otp = PhoneOtpService(factory, sender=sender, secret='activation-test-secret', now=lambda: clock[0])
    with factory.begin() as session:
        session.add(User(id='staff', username='staff', username_normalized='staff',
            phone_normalized='+8613800000000', phone='+8613800000000', phone_verified_at=clock[0],
            password_hash=PasswordHasher().hash('correct password 123'), status=AccountStatus.ACTIVE,
            created_at=clock[0], updated_at=clock[0]))
        session.add(UserRole(id='role', user_id='staff', role_code=RoleCode.SUPPORT_AGENT,
            assigned_by='admin', assigned_at=clock[0]))
    return factory, clock, sender, StaffActivationService(factory, phone_otp=otp,
        email_code_deriver=lambda value: '846291', now=lambda: clock[0])


def issue(env):
    return env[3].request(username='staff', password='correct password 123')


def test_activation_feature_exists():
    import app.modules.identity as identity
    import importlib.util
    assert importlib.util.find_spec(identity.__name__ + '.staff_activation') is not None


def test_activation_binds_same_user_without_granting_roles(env):
    factory, clock, sender, service = env
    result = issue(env)
    assert result['channel'] == 'phone'
    assert '+8613800000000' not in str(result)
    assert sender.messages[-1][2] == 'staff_activation_phone'
    assert service.confirm(activation_id=result['activation_id'], code=sender.messages[-1][1]) == {'status': 'activated', 'user_id': 'staff'}
    with factory() as session:
        assert len(session.scalars(select(User)).all()) == 1
        assert session.scalars(select(UserRole.role_code)).all() == [RoleCode.SUPPORT_AGENT]
    with pytest.raises(AppError):
        service.confirm(activation_id=result['activation_id'], code=sender.messages[-1][1])
    with pytest.raises(AppError) as error:
        issue(env)
    assert error.value.code == 'STAFF_ALREADY_ACTIVATED'


@pytest.mark.parametrize('change', ['ordinary', 'inactive', 'unverified', 'password'])
def test_rejects_ineligible_before_send(env, change):
    factory, _, sender, service = env
    with factory.begin() as session:
        user = session.get(User, 'staff')
        if change == 'ordinary': session.execute(delete(UserRole))
        if change == 'inactive': user.status = AccountStatus.PENDING_PHONE
        if change == 'unverified': user.phone_verified_at = None
    with pytest.raises(AppError):
        service.request(username='staff', password='wrong' if change == 'password' else 'correct password 123')
    assert not sender.messages


@pytest.mark.parametrize('change', ['contact', 'contact_epoch', 'role', 'inactive', 'expired'])
def test_changed_identity_invalidates_pending_challenge(env, change):
    factory, clock, sender, service = env
    result = issue(env)
    with factory.begin() as session:
        user = session.get(User, 'staff')
        if change == 'contact': user.phone_normalized = '+8613900000000'
        if change == 'contact_epoch': user.phone_verified_at = clock[0] + timedelta(seconds=1)
        if change == 'role': session.delete(session.get(UserRole, 'role'))
        if change == 'inactive': user.status = AccountStatus.PENDING_PHONE
    if change == 'expired': clock[0] += timedelta(seconds=300)
    with pytest.raises(AppError):
        service.confirm(activation_id=result['activation_id'], code=sender.messages[-1][1])


def test_wrong_attempts_persist_and_exhaust(env):
    factory, _, sender, service = env
    result = issue(env)
    for _ in range(5):
        with pytest.raises(AppError): service.confirm(activation_id=result['activation_id'], code='not-a-code')
    with pytest.raises(AppError): service.confirm(activation_id=result['activation_id'], code=sender.messages[-1][1])
    with factory() as session:
        assert session.scalar(select(OtpChallenge)).attempts_left == 0


def test_resend_quota_and_old_challenge(env):
    _, _, sender, service = env
    old = issue(env)
    old_code = sender.messages[-1][1]
    issue(env)
    with pytest.raises(AppError): service.confirm(activation_id=old['activation_id'], code=old_code)
    issue(env)
    with pytest.raises(AppError) as error: issue(env)
    assert error.value.code == 'OTP_SEND_RATE_LIMITED'


def test_provider_outage_never_activates(env):
    factory, _, sender, service = env
    def fail(*args): raise AppError(code='SMS_PROVIDER_UNAVAILABLE', message='unavailable', status_code=503)
    sender.send = fail
    with pytest.raises(AppError): issue(env)
    with factory() as session:
        row = session.scalar(select(OtpChallenge))
        assert row.invalidated_at is not None and row.attempts_left == 0


def test_verified_email_uses_outbox_and_purpose_bound_code(env):
    from app.core.outbox import OutboxEvent
    factory, clock, sender, service = env
    with factory.begin() as session:
        user = session.get(User, 'staff')
        user.phone_normalized = None
        user.email_normalized = 'staff@example.invalid'
        user.email_verified_at = clock[0]
    result = issue(env)
    assert result['channel'] == 'email' and not sender.messages
    with factory() as session:
        row = session.scalar(select(OtpChallenge))
        assert row.purpose == 'staff_activation_email'
        event = session.scalar(select(OutboxEvent).where(OutboxEvent.event_type == 'identity.email.otp.requested'))
        assert event.payload == {'otp_id': row.id}
        assert '846291' not in str(event.payload)
    assert service.confirm(activation_id=result['activation_id'], code='846291')['status'] == 'activated'


@pytest.mark.parametrize('revoked', [False, True])
@pytest.mark.parametrize('has_phone', [False, True])
def test_email_worker_rechecks_bound_staff_before_delivery(env, revoked, has_phone):
    from importlib import import_module
    from types import SimpleNamespace
    from app.core.outbox import OutboxEvent, OutboxMessage
    from app.modules.identity.registration import VerificationTokenCodec
    factory, clock, _, service = env
    with factory.begin() as session:
        user=session.get(User,'staff')
        if not has_phone: user.phone_normalized=None
        user.email_normalized='staff@example.invalid'
        user.email_verified_at=clock[0]
    service.request(username='staff', password='correct password 123', channel='email')
    with factory.begin() as session:
        event=session.scalar(select(OutboxEvent).where(OutboxEvent.event_type=='identity.email.otp.requested'))
        if revoked: session.delete(session.get(UserRole,'role'))
        message=OutboxMessage(id=event.id,topic=event.topic,event_type=event.event_type,
            aggregate_type=event.aggregate_type,aggregate_id=event.aggregate_id,payload=event.payload,headers={},attempt_count=1)
    sent=[]
    task=import_module('tasks.identity').IdentityEmailVerificationTask(factory,
        token_codec=VerificationTokenCodec(b'test-email-verification-secret'),public_base_url='https://test.invalid',
        email_sender=SimpleNamespace(send_email_otp=lambda **body:sent.append(body)),now_factory=lambda:clock[0])
    task(message)
    assert len(sent)==(0 if revoked else 1)


def test_staff_admin_sessions_require_activation_and_revalidate_identity(env):
    from app.modules.identity.tokens import TokenService
    factory, clock, sender, service = env
    tokens = TokenService(factory, jwt_secret='test-jwt-secret-at-least-thirty-two-bytes', jwt_issuer='test')
    with pytest.raises(AppError) as error:
        tokens.issue_admin_pair(user_id='staff', display_name='staff browser')
    assert error.value.code == 'STAFF_ACTIVATION_REQUIRED'
    result = issue(env)
    service.confirm(activation_id=result['activation_id'], code=sender.messages[-1][1])
    mobile = tokens.issue_pair(user_id='staff', device_key='app', display_name='APP')
    pair = tokens.issue_admin_pair(user_id='staff', display_name='staff browser')
    assert tokens.decode_access_token(pair.access_token)['session_scope'] == 'admin'
    assert tokens.decode_access_token(mobile.access_token)['sub'] == 'staff'
    with factory.begin() as session: session.delete(session.get(UserRole, 'role'))
    with pytest.raises(AppError): tokens.decode_access_token(pair.access_token)
    with pytest.raises(AppError): tokens.rotate_admin(pair.refresh_token)


@pytest.mark.asyncio
async def test_activation_http_requires_credentials_csrf_and_server_bound_destination(env, monkeypatch):
    from httpx import ASGITransport, AsyncClient
    from app.core.config import Settings
    from app.main import create_app
    factory, _, sender, service = env
    monkeypatch.setattr('app.modules.identity.login_captcha.LoginCaptcha.verify', lambda *args: None)
    # Replace only the provider in this test; no real SMS request is made.
    monkeypatch.setattr('app.modules.identity.phone.NullSmsSender.send', sender.send)
    app = create_app(Settings(_env_file=None, environment='test', phone_auth_enabled=True,
        jwt_secret='test-jwt-secret-at-least-thirty-two-bytes'), session_factory=factory)
    body = dict(username='staff', password='correct password 123', challenge_id='x'*32, captcha_answer='ABCDEF')
    csrf = {'Origin':'https://test', 'X-Admin-CSRF':'1'}
    async with AsyncClient(transport=ASGITransport(app=app), base_url='https://test') as client:
        path = '/api/v1/auth/staff-activation/challenges'
        assert (await client.post(path, json=body)).status_code == 403
        assert (await client.post(path, json={**body, 'phone':'+8613900000000'}, headers=csrf)).status_code == 422
        response = await client.post(path, json=body, headers=csrf)
        assert response.status_code == 202, response.text
        assert 'access_token' not in response.json()
        activation_id = response.json()['activation_id']
        result = await client.post('/api/v1/auth/staff-activation/confirm', headers=csrf,
            json={'activation_id': activation_id, 'code':sender.messages[-1][1]})
        assert result.status_code == 200, result.text
        logged = await client.post('/api/v1/auth/admin-login', headers=csrf,
            json={**body, 'device_key':'browser', 'device_name':'Browser'})
        assert logged.status_code == 200, logged.text
        assert 'HttpOnly' in logged.headers['set-cookie']


def test_finance_staff_own_scoped_grant_cannot_authorize_owner_wallet(env):
    from types import SimpleNamespace
    from app.modules.identity.tokens import TokenService
    from app.modules.identity.operation_password import AdminWalletOperationPasswordService
    from app.modules.identity.wallet_grant import WalletAccessGrantService
    factory, clock, sender, activation = env
    with factory.begin() as session: session.get(UserRole, 'role').role_code = RoleCode.FINANCE_SUPPORT
    result = issue(env)
    activation.confirm(activation_id=result['activation_id'], code=sender.messages[-1][1])
    tokens = TokenService(factory, jwt_secret='test-jwt-secret-at-least-thirty-two-bytes', jwt_issuer='test', now_factory=lambda:clock[0])
    pair = tokens.issue_admin_pair(user_id='staff', display_name='staff')
    claims = tokens.decode_access_token(pair.access_token)
    settings = SimpleNamespace(wallet_admin_auth_mode='operation_password',wallet_manual_owner_admin_id='owner',
        wallet_real_mode='manual_tron',wallet_access_grant_enabled=True)
    operations = AdminWalletOperationPasswordService(factory,owner_id=lambda:'owner',
        auth_mode=lambda:'operation_password',clock=lambda:clock[0],scope='support-orders')
    operations.set_password(claims=claims,login_password='correct password 123',
        new_operation_password='separate operation password',idempotency_key='setup')
    grants = WalletAccessGrantService(settings,factory,lambda:clock[0],scope='support-orders')
    result = grants.verify(claims=claims,operation_password='separate operation password')
    assert result['verified'] and result['scope']=='support-orders'
    grants.require(claims=claims)
    owner_grants = WalletAccessGrantService(settings,factory,lambda:clock[0])
    with pytest.raises(AppError): owner_grants.require(claims=claims)
    with factory.begin() as session: session.delete(session.get(UserRole,'role'))
    with pytest.raises(AppError): grants.require(claims=claims)


@pytest.mark.asyncio
async def test_support_security_http_rejects_app_scope_and_accepts_activated_finance(env):
    from httpx import ASGITransport, AsyncClient
    from app.core.config import Settings
    from app.main import create_app
    from app.modules.identity.tokens import TokenService
    factory, _, sender, activation = env
    with factory.begin() as session: session.get(UserRole,'role').role_code = RoleCode.FINANCE_SUPPORT
    result=issue(env)
    activation.confirm(activation_id=result['activation_id'],code=sender.messages[-1][1])
    settings=Settings(_env_file=None,environment='test',jwt_secret='test-jwt-secret-at-least-thirty-two-bytes').model_copy(update={
        'wallet_admin_auth_mode':'operation_password','wallet_manual_owner_admin_id':'owner',
        'wallet_real_mode':'manual_tron','wallet_access_grant_enabled':True})
    tokens=TokenService(factory,jwt_secret=settings.jwt_secret,jwt_issuer=settings.jwt_issuer)
    from fastapi import FastAPI
    from app.core.errors import install_error_handlers
    from app.api.support_order_security import create_support_order_security_router
    app=FastAPI()
    install_error_handlers(app)
    app.include_router(create_support_order_security_router(settings,factory),prefix='/api/v1')
    admin=tokens.issue_admin_pair(user_id='staff',display_name='staff')
    mobile=tokens.issue_pair(user_id='staff',device_key='app',display_name='app')
    async with AsyncClient(transport=ASGITransport(app=app),base_url='https://test') as client:
        path='/api/v1/admin/support-orders/security'
        response=await client.get(path,headers={'Authorization':'Bearer '+mobile.access_token})
        assert response.status_code==403,response.text
        headers={'Authorization':'Bearer '+admin.access_token}
        response=await client.get(path,headers=headers)
        assert response.status_code==200,response.text
        assert response.json()['configured'] is True
        assert response.json()['verified'] is True
        assert response.json()['auth_mode'] == 'session'
        response=await client.put(path+'/operation-password',headers={**headers,'Idempotency-Key':'http-setup'},
            json={'login_password':'correct password 123','new_operation_password':'separate operation password'})
        assert response.status_code==200,response.text
        response=await client.post(path+'/verify',headers=headers,json={'operation_password':'separate operation password'})
        assert response.status_code==200,response.text
        assert response.json()['verified'] is True


@pytest.mark.parametrize('purpose', ['staff_activation_email', 'email_rebind_old'])
def test_email_otp_worker_uses_real_smtp_adapter(env, purpose):
    from app.core.outbox import OutboxEvent, OutboxMessage
    from app.modules.identity.registration import VerificationTokenCodec
    from integrations.email_sender import SmtpConfig, SmtpEmailSender
    from tasks.identity import IdentityEmailVerificationTask
    factory, clock, _, service = env
    codec = VerificationTokenCodec(b'fixture-email-code-secret')
    service.email_otp.code_deriver = codec.verification_code
    with factory.begin() as session:
        user = session.get(User, 'staff')
        user.phone_normalized = None
        user.email_normalized = 'staff@example.invalid'
        user.email_verified_at = clock[0]
    issue(env)
    with factory.begin() as session:
        otp = session.scalar(select(OtpChallenge))
        otp.purpose = purpose
        expected_code = codec.verification_code(otp.id)
        event = session.scalar(select(OutboxEvent).where(OutboxEvent.event_type == 'identity.email.otp.requested'))
        message = OutboxMessage(id=event.id, topic=event.topic, event_type=event.event_type,
            aggregate_type=event.aggregate_type, aggregate_id=event.aggregate_id,
            payload=event.payload, headers={}, attempt_count=1)
    delivered = []
    class Smtp:
        def __init__(self, *args, **kwargs): pass
        def __enter__(self): return self
        def __exit__(self, *args): return False
        def starttls(self, *, context): assert context is not None
        def send_message(self, message): delivered.append(message)
    sender = SmtpEmailSender(SmtpConfig(host='smtp.example.invalid', port=587,
        from_address='noreply@example.invalid', use_starttls=True), smtp_factory=Smtp)
    task = IdentityEmailVerificationTask(factory, token_codec=codec,
        public_base_url='https://example.invalid', email_sender=sender, now_factory=lambda: clock[0])
    task(message)
    assert len(delivered) == 1
    mail = delivered[0]
    assert mail['To'] == 'staff@example.invalid'
    assert expected_code in mail.get_content()
    assert ('客服后台首次开通' if purpose == 'staff_activation_email' else '绑定手机') in mail.get_content()
    assert '5 分钟' in mail.get_content()
    assert '钱包告警' not in mail['Subject']
    clock[0] += timedelta(seconds=301)
    task(message)
    assert len(delivered) == 1
