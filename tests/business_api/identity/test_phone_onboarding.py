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
