"""Verified-phone onboarding preserves invitations, OTP and Matrix boundaries."""
from sqlalchemy import select
import pytest
import app.modules.audit.models  # noqa: F401

from app.core.errors import AppError
from app.core.outbox import OutboxEvent
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User, OtpChallenge, Invitation
from app.modules.identity.phone import PhoneAuthService
from test_phone_auth import env  # noqa: F401


def onboard(env, **kwargs):
    factory, registration, otp, _, sender, clock, _ = env
    auth = PhoneAuthService(factory, otp=otp, now=clock, registration=registration)
    auth.request_login_otp(phone='13800000001')
    assert sender.messages, 'unknown verified phone must receive real OTP delivery'
    code = sender.messages[-1][1]
    defaults = dict(phone='13800000001', code=code, tokens=None,
                    device_key='test-device', device_name='test',
                    invitation_code='WELCOME-1', terms_accepted=True)
    defaults.update(kwargs)
    return auth, defaults


def test_unknown_phone_is_created_only_after_proof_and_invitation(env):
    auth, args = onboard(env)
    factory = env[0]
    with factory() as session:
        assert session.scalars(select(User)).all() == []
    with pytest.raises(AppError, match='验证码'):
        auth.login(**{**args, 'code': 'wrong'})
    with pytest.raises(AppError) as error:
        auth.login(**{**args, 'invitation_code': ''})
    assert error.value.code == 'INVITATION_REQUIRED'
    with pytest.raises(AppError) as error:
        auth.login(**{**args, 'terms_accepted': False})
    assert error.value.code == 'TERMS_REQUIRED'
    result = auth.login(**args)
    assert result['status'] == 'PENDING_MATRIX'
    assert len(result['login_ticket']) >= 32
    with factory() as session:
        user = session.scalar(select(User))
        assert user.phone_verified_at and user.status == AccountStatus.PENDING_MATRIX
        assert '13800000001' not in user.username and user.nickname == '畅聊用户0001'
        assert user.email is None
        assert session.scalar(select(Invitation)).use_count == 1
        assert len(session.scalars(select(OutboxEvent)).all()) == 1
        assert all(result['login_ticket'] not in str(row.__dict__)
                   for row in session.scalars(select(OtpChallenge)))
    with pytest.raises(AppError):
        auth.login(**args)


def test_verified_invitation_continuation_never_rechecks_provider(env):
    auth, args = onboard(env, invitation_code='')
    factory, _, otp, _, sender, _, _ = env
    checks = []

    def verify_once(target, purpose, code, challenge_id):
        checks.append((purpose, challenge_id))
        return len(checks) == 1 and code == sender.messages[-1][1]

    otp.code_verifier = verify_once
    pending = auth.login(**args, allow_invitation_continuation=True)
    assert pending['status'] == 'INVITATION_VERIFIED'
    ticket = pending['invitation_ticket']
    assert len(ticket) >= 32
    with factory() as session:
        assert session.scalars(select(User)).all() == []
        assert session.scalar(select(Invitation)).use_count == 0
        assert session.scalars(select(OutboxEvent)).all() == []
        rows = session.scalars(select(OtpChallenge)).all()
        assert len(rows) == 2
        assert next(row for row in rows if row.purpose == 'login').consumed_at is not None
        proof = next(row for row in rows if row.purpose == 'login_invitation')
        assert ticket != proof.target
        assert args['code'] != proof.code_hash
        assert args['phone'] not in (proof.target, proof.registration_session,
                                     proof.code_hash)

    correction = dict(invitation_ticket=ticket, phone=args['phone'],
                      device_key=args['device_key'], device_name=args['device_name'],
                      invitation_code='', terms_accepted=True, tokens=None)
    assert auth.complete_invitation(**correction) == {
        'status': 'INVITATION_REQUIRED', 'invitation_ticket': ticket}
    assert auth.complete_invitation(**{**correction, 'terms_accepted': False}) == {
        'status': 'TERMS_REQUIRED', 'invitation_ticket': ticket}
    assert auth.complete_invitation(**{**correction, 'invitation_code': 'wrong'}) == {
        'status': 'INVITATION_INVALID', 'invitation_ticket': ticket}
    with pytest.raises(AppError) as error:
        auth.complete_invitation(**{**correction, 'device_key': 'other-device'})
    assert error.value.code == 'INVITATION_TICKET_INVALID'
    with pytest.raises(AppError) as error:
        auth.complete_invitation(**{**correction, 'phone': '13900000002'})
    assert error.value.code == 'INVITATION_TICKET_INVALID'

    result = auth.complete_invitation(**{**correction, 'invitation_code': 'WELCOME-1'})
    assert result == {
        'status': 'PENDING_MATRIX', 'login_ticket': ticket, 'retry_after_seconds': 2}
    assert len(checks) == 1
    with factory() as session:
        assert len(session.scalars(select(User)).all()) == 1
        assert session.scalar(select(Invitation)).use_count == 1
        assert len(session.scalars(select(OutboxEvent)).all()) == 1
        proof = session.scalar(select(OtpChallenge).where(
            OtpChallenge.purpose == 'login_resume'))
        assert proof is not None and proof.user_id is not None
    # A lost invitation response can be retried with the original ticket.
    assert auth.complete_invitation(**correction)['login_ticket'] == ticket
    with pytest.raises(AppError) as error:
        auth.login(**args, allow_invitation_continuation=True)
    assert error.value.code == 'OTP_INVALID'


def test_invitation_correction_bounded_and_expires_without_new_sms(env):
    auth, args = onboard(env, invitation_code='')
    ticket = auth.login(**args, allow_invitation_continuation=True)['invitation_ticket']
    correction = dict(invitation_ticket=ticket, phone=args['phone'],
                      device_key=args['device_key'], device_name=args['device_name'],
                      invitation_code='bad-invite', terms_accepted=True, tokens=None)
    for _ in range(4):
        result = auth.complete_invitation(**correction)
        assert result == {'status': 'INVITATION_INVALID', 'invitation_ticket': ticket}
    with pytest.raises(AppError) as error:
        auth.complete_invitation(**correction)
    assert error.value.code == 'INVITATION_TICKET_INVALID'
    with pytest.raises(AppError) as error:
        auth.complete_invitation(**{**correction, 'invitation_code': 'WELCOME-1'})
    assert error.value.code == 'INVITATION_TICKET_INVALID'
    with env[0]() as session:
        assert session.scalars(select(User)).all() == []
        assert session.scalar(select(Invitation)).use_count == 0
        assert session.scalars(select(OutboxEvent)).all() == []

    auth2, args2 = onboard(env, invitation_code='')
    auth2.request_login_otp(phone='13900000002')
    args2 = {**args2, 'phone': '13900000002', 'code': env[4].messages[-1][1]}
    ticket2 = auth2.login(**args2, allow_invitation_continuation=True)['invitation_ticket']
    env[5].advance(minutes=6)
    with pytest.raises(AppError) as error:
        auth2.complete_invitation(**{**correction, 'invitation_ticket': ticket2,
                                      'phone': args2['phone'],
                                      'invitation_code': 'WELCOME-1'})
    assert error.value.code == 'INVITATION_TICKET_INVALID'


def test_invitation_proof_expiring_during_row_lookup_is_rejected(env):
    from sqlalchemy import event

    auth, args = onboard(env, invitation_code='')
    ticket = auth.login(**args, allow_invitation_continuation=True)['invitation_ticket']
    engine = env[0].kw['bind']
    clock = env[5]
    advanced = False

    def cross_expiry_while_lookup_waits(connection, cursor, statement, parameters,
                                        context, executemany):
        nonlocal advanced
        if not advanced and 'otp_challenges' in statement and (
                isinstance(parameters, tuple) and 'login_invitation' in parameters):
            clock.advance(minutes=6)
            advanced = True

    event.listen(engine, 'before_cursor_execute', cross_expiry_while_lookup_waits)
    try:
        with pytest.raises(AppError) as error:
            auth.complete_invitation(invitation_ticket=ticket, phone=args['phone'],
                device_key=args['device_key'], device_name=args['device_name'],
                invitation_code='WELCOME-1', terms_accepted=True, tokens=None)
    finally:
        event.remove(engine, 'before_cursor_execute', cross_expiry_while_lookup_waits)
    assert advanced
    assert error.value.code == 'INVITATION_TICKET_INVALID'
    with env[0]() as session:
        assert session.scalars(select(User)).all() == []
        assert session.scalar(select(Invitation)).use_count == 0
        assert session.scalars(select(OutboxEvent)).all() == []


def test_invitation_proof_expiring_during_registration_rolls_back(env):
    auth, args = onboard(env, invitation_code='')
    ticket = auth.login(**args, allow_invitation_continuation=True)['invitation_ticket']

    def delay_after_registration_write():
        env[5].advance(minutes=6)

    with pytest.raises(AppError) as error:
        auth.complete_invitation(invitation_ticket=ticket, phone=args['phone'],
            device_key=args['device_key'], device_name=args['device_name'],
            invitation_code='WELCOME-1', terms_accepted=True, tokens=None,
            on_new_account=delay_after_registration_write)
    assert error.value.code == 'INVITATION_TICKET_INVALID'
    with env[0]() as session:
        assert session.scalars(select(User)).all() == []
        assert session.scalar(select(Invitation)).use_count == 0
        assert session.scalars(select(OutboxEvent)).all() == []


def test_invitation_continuation_rate_gate_rolls_back_registration(env):
    auth, args = onboard(env, invitation_code='')
    ticket = auth.login(**args, allow_invitation_continuation=True)['invitation_ticket']
    correction = dict(invitation_ticket=ticket, phone=args['phone'],
                      device_key=args['device_key'], device_name=args['device_name'],
                      invitation_code='WELCOME-1', terms_accepted=True, tokens=None)

    def limit():
        raise AppError(code='RATE_LIMITED', message='请求过于频繁', status_code=429)

    with pytest.raises(AppError) as error:
        auth.complete_invitation(**correction, on_new_account=limit)
    assert error.value.code == 'RATE_LIMITED'
    with env[0]() as session:
        assert session.scalars(select(User)).all() == []
        assert session.scalar(select(Invitation)).use_count == 0
        assert session.scalars(select(OutboxEvent)).all() == []
        assert session.scalar(select(OtpChallenge).where(
            OtpChallenge.purpose == 'login_invitation')).consumed_at is None
    assert auth.complete_invitation(**correction)['login_ticket'] == ticket


def test_ticket_waits_for_matrix_and_cannot_switch_device_or_replay(env):
    from app.modules.identity.tokens import TokenService
    auth, args = onboard(env)
    result = auth.login(**args)
    tokens = TokenService(env[0], jwt_secret='test-secret-at-least-thirty-two-bytes', jwt_issuer='test', now_factory=env[5])
    ticket_args = dict(login_ticket=result['login_ticket'], device_key='test-device',
                       device_name='test', tokens=tokens)
    assert auth.complete_login(**ticket_args)['status'] == 'PENDING_MATRIX'
    with pytest.raises(AppError):
        auth.complete_login(**{**ticket_args, 'device_key': 'different-device'})
    with env[0].begin() as session:
        user = session.scalar(select(User))
        user.status = AccountStatus.ACTIVE
        user.matrix_user_id = '@opaque:test'
    assert auth.complete_login(**ticket_args).access_token
    with pytest.raises(AppError):
        auth.complete_login(**ticket_args)


def test_existing_registration_rate_gate_rolls_back_all_signup_state(env):
    auth, args = onboard(env)
    def limit():
        raise AppError(code='RATE_LIMITED', message='请求过于频繁', status_code=429)
    with pytest.raises(AppError) as error:
        auth.login(**args, on_new_account=limit)
    assert error.value.code == 'RATE_LIMITED'
    with env[0]() as session:
        assert session.scalars(select(User)).all() == []
        assert session.scalar(select(Invitation)).use_count == 0
        assert session.scalar(select(OtpChallenge)).consumed_at is None


@pytest.mark.parametrize('mutation', ['expired', 'revoked', 'suspended', 'disabled', 'phone_changed', 'unverified'])
def test_ticket_rejects_expired_revoked_or_locked_accounts(env, mutation):
    auth, args = onboard(env)
    ticket = auth.login(**args)['login_ticket']
    if mutation == 'expired':
        env[5].advance(minutes=6)
    else:
        with env[0].begin() as session:
            if mutation == 'revoked':
                session.scalar(select(OtpChallenge).where(
                    OtpChallenge.purpose == 'login_resume')).invalidated_at = env[5]()
            elif mutation == 'phone_changed':
                session.scalar(select(User)).phone_normalized = '+8613900000002'
            elif mutation == 'unverified':
                session.scalar(select(User)).phone_verified_at = None
            else:
                session.scalar(select(User)).status = AccountStatus(mutation.upper())
    with pytest.raises(AppError):
        auth.complete_login(login_ticket=ticket, device_key='test-device', device_name='test', tokens=None)


def test_login_cannot_activate_attacker_pre_registered_phone(env):
    from test_phone_auth import _register_phone
    original = _register_phone(env)
    auth, args = onboard(env, invitation_code='')
    with pytest.raises(AppError) as error:
        auth.login(**args)
    assert error.value.code == 'PHONE_REGISTRATION_INCOMPLETE'
    with env[0]() as session:
        assert [u.id for u in session.scalars(select(User))] == [original.user_id]
        assert session.get(User, original.user_id).status == AccountStatus.PENDING_PHONE
        assert session.get(User, original.user_id).phone_verified_at is None
        assert session.scalars(select(OutboxEvent)).all() == []
        assert session.scalars(select(OtpChallenge).where(OtpChallenge.purpose == 'login_resume')).all() == []
        assert session.scalar(select(Invitation)).use_count == 1


@pytest.mark.asyncio
async def test_public_phone_onboarding_and_completion_contract(env):
    from datetime import datetime, timedelta, timezone
    from fastapi import FastAPI
    from httpx import ASGITransport, AsyncClient
    from app.api.identity import create_identity_router
    from app.core.config import Settings
    from app.core.errors import install_error_handlers
    from app.core.rate_limits import NoopRateLimiter
    from app.modules.identity.provisioning import MatrixProvisionTask
    from app.integrations.matrix_admin import MatrixCredentialCodec
    from types import SimpleNamespace

    env[6].issue(code='API-INVITE', max_uses=1,
                 expires_at=datetime.now(timezone.utc)+timedelta(days=1), created_by='test')
    settings = Settings(_env_file=None, environment='test', database_url='sqlite://',
        redis_url='redis://localhost:6379/15', phone_auth_enabled=True,
        jwt_secret='test-jwt-secret-at-least-thirty-two-bytes')
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(create_identity_router(settings, env[0], NoopRateLimiter(),
        matrix_gateway=SimpleNamespace(), sms_sender=env[4]), prefix='/api/v1')
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        base = '/api/v1/auth/phone/login'
        assert (await client.post(base+'/request', json={'phone':'13800000001'})).status_code == 202
        body = dict(phone='13800000001', code=env[4].messages[-1][1],
                    device_key='api-device', device_name='test', terms_accepted=True)
        missing = await client.post(base, json=body)
        assert missing.status_code == 422
        response = await client.post(base, json={**body, 'invitation_code':'API-INVITE'})
        assert response.status_code == 202, response.text
        proof = dict(login_ticket=response.json()['login_ticket'], device_key='api-device', device_name='test')
        assert (await client.post(base+'/complete', json=proof)).status_code == 202
        with env[0]() as session:
            event = session.scalar(select(OutboxEvent).where(
                OutboxEvent.event_type == 'identity.matrix.provision.requested'))
        task = MatrixProvisionTask(env[0], gateway=SimpleNamespace(ensure_user=lambda localpart, password: '@'+localpart+':test'),
            credential_codec=MatrixCredentialCodec(b'test-matrix-provision-secret'))
        task(event)
        task(event)
        done = await client.post(base+'/complete', json=proof)
        assert done.status_code == 200, done.text
        assert done.json()['matrix_user_id'].startswith('@p')
        assert (await client.post(base+'/complete', json=proof)).status_code == 401


@pytest.mark.asyncio
async def test_public_invitation_continuation_contract(env):
    from datetime import datetime, timedelta, timezone
    from fastapi import FastAPI
    from httpx import ASGITransport, AsyncClient
    from app.api.identity import create_identity_router
    from app.core.config import Settings
    from app.core.errors import install_error_handlers
    from app.core.rate_limits import NoopRateLimiter
    from types import SimpleNamespace

    env[6].issue(code='API-INVITE', max_uses=1,
                 expires_at=datetime.now(timezone.utc)+timedelta(days=1), created_by='test')
    settings = Settings(_env_file=None, environment='test', database_url='sqlite://',
        redis_url='redis://localhost:6379/15', phone_auth_enabled=True,
        jwt_secret='test-jwt-secret-at-least-thirty-two-bytes')
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(create_identity_router(settings, env[0], NoopRateLimiter(),
        matrix_gateway=SimpleNamespace(), sms_sender=env[4]), prefix='/api/v1')
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        base = '/api/v1/auth/phone/login'
        assert (await client.post(base+'/request', json={'phone':'13800000001'})).status_code == 202
        body = dict(phone='13800000001', code=env[4].messages[-1][1],
                    device_key='api-device', device_name='test',
                    allow_invitation_continuation=True)
        verified = await client.post(base, json=body)
        assert verified.status_code == 202, verified.text
        assert verified.json()['status'] == 'INVITATION_VERIFIED'
        assert verified.headers['cache-control'] == 'no-store'
        ticket = verified.json()['invitation_ticket']
        correction = dict(invitation_ticket=ticket, phone=body['phone'],
                          device_key=body['device_key'], device_name=body['device_name'],
                          invitation_code='', terms_accepted=True)
        missing = await client.post(base+'/invitation', json=correction)
        assert missing.status_code == 202
        assert missing.json() == {'status': 'INVITATION_REQUIRED', 'invitation_ticket': ticket}
        done = await client.post(base+'/invitation', json={**correction, 'invitation_code':'API-INVITE'})
        assert done.status_code == 202, done.text
        assert done.json()['status'] == 'PENDING_MATRIX'
        assert done.json()['login_ticket'] == ticket
        retry = await client.post(base+'/invitation', json=correction)
        assert retry.status_code == 202
        assert retry.json()['login_ticket'] == ticket


@pytest.mark.asyncio
async def test_invitation_route_has_ip_limit_independent_of_ticket(env):
    from fastapi import FastAPI
    from httpx import ASGITransport, AsyncClient
    from app.api.identity import create_identity_router, public_rate_limit_key
    from app.core.config import Settings
    from app.core.errors import install_error_handlers
    from types import SimpleNamespace

    class RecordingLimiter:
        def __init__(self):
            self.keys = []

        def hit(self, key, *, limit, window_seconds):
            self.keys.append(key)

    settings = Settings(_env_file=None, environment='test', database_url='sqlite://',
        redis_url='redis://localhost:6379/15', phone_auth_enabled=True,
        jwt_secret='test-jwt-secret-at-least-thirty-two-bytes')
    limiter = RecordingLimiter()
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(create_identity_router(settings, env[0], limiter,
        matrix_gateway=SimpleNamespace(), sms_sender=env[4]), prefix='/api/v1')
    body = dict(phone='13800000001', device_key='api-device', device_name='test',
                invitation_code='API-INVITE', terms_accepted=True)
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        for ticket in ('a' * 43, 'b' * 43):
            response = await client.post('/api/v1/auth/phone/login/invitation',
                json={**body, 'invitation_ticket': ticket})
            assert response.status_code == 401
    expected = public_rate_limit_key('auth:phone-login-invitation-ip', '127.0.0.1')
    assert limiter.keys.count(expected) == 2
