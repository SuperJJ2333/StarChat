from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import create_engine, select

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.main import create_app
from app.modules.identity.enums import AccountStatus, RoleCode
from app.modules.identity.models import User, UserRole, RefreshTokenFamily
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.tokens import TokenService


@pytest.fixture
def components(tmp_path):
    engine = create_engine(f'sqlite:///{tmp_path / "sessions.db"}')
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    clock = [datetime.now(timezone.utc)]
    hasher = PasswordHasher()
    with factory.begin() as session:
        for user_id in ('alice', 'bob'):
            session.add(User(id=user_id, username=user_id, username_normalized=user_id,
                email=f'{user_id}@test.invalid', email_normalized=f'{user_id}@test.invalid',
                password_hash=hasher.hash('correct password 123'), status=AccountStatus.ACTIVE,
                created_at=clock[0], updated_at=clock[0]))
            session.add(UserRole(id=user_id, user_id=user_id, role_code=RoleCode.SUPER_ADMIN,
                assigned_by=user_id, assigned_at=clock[0]))
    tokens = TokenService(factory, jwt_secret='test-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer='liuhetong', now_factory=lambda: clock[0])
    return factory, tokens, clock


def test_admin_replacement_does_not_revoke_mobile_or_other_admin(components):
    factory, tokens, clock = components
    mobile = tokens.issue_pair(user_id='alice', device_key='shared', display_name='Mobile')
    first = tokens.issue_admin_pair(user_id='alice', display_name='Browser')
    other = tokens.issue_admin_pair(user_id='bob', display_name='Browser')
    second = tokens.issue_admin_pair(user_id='alice', display_name='Browser')
    with pytest.raises(AppError):
        tokens.decode_access_token(first.access_token)
    with pytest.raises(AppError):
        tokens.rotate_admin(first.refresh_token)
    assert tokens.decode_access_token(second.access_token)['session_scope'] == 'admin'
    assert tokens.decode_access_token(mobile.access_token)['sub'] == 'alice'
    assert tokens.decode_access_token(other.access_token)['sub'] == 'bob'
    assert tokens.rotate(mobile.refresh_token)


def test_absolute_expiry_and_refresh_cannot_cross_domains(components):
    factory, tokens, clock = components
    pair = tokens.issue_admin_pair(user_id='alice', display_name='Browser')
    deadline = clock[0] + timedelta(hours=48)
    with pytest.raises(AppError):
        tokens.rotate(pair.refresh_token)
    mobile = tokens.issue_pair(user_id='alice', device_key='mobile', display_name='Mobile')
    with pytest.raises(AppError):
        tokens.rotate_admin(mobile.refresh_token)
    clock[0] = deadline - timedelta(seconds=1)
    renewed = tokens.rotate_admin(pair.refresh_token)
    assert tokens.admin_session(renewed.access_token)['session_expires_at'] == deadline
    clock[0] = deadline
    with pytest.raises(AppError):
        tokens.decode_access_token(renewed.access_token)
    with pytest.raises(AppError):
        tokens.rotate_admin(renewed.refresh_token)


def test_wallet_transaction_accepts_admin_step_up_without_renewing_mobile_age(components):
    from app.modules.identity.operation_password import AdminWalletOperationPasswordService
    from app.modules.identity.wallet_access import require_wallet_session
    factory, tokens, clock = components
    pair = tokens.issue_admin_pair(user_id='alice', display_name='Browser')
    mobile = tokens.issue_pair(user_id='alice', device_key='mobile', display_name='Mobile')
    claims = tokens.decode_access_token(pair.access_token)
    mobile_claims = tokens.decode_access_token(mobile.access_token)
    service = AdminWalletOperationPasswordService(factory, owner_id=lambda: 'alice',
        auth_mode=lambda: 'operation_password', clock=lambda: clock[0])
    clock[0] += timedelta(minutes=6)
    with pytest.raises(AppError, match='请重新登录'):
        service.status(claims=claims)
    tokens.step_up_admin(pair.access_token, 'correct password 123')
    assert service.status(claims=claims)['configured'] is False
    with factory.begin() as session:
        with pytest.raises(AppError) as error:
            require_wallet_session(session, claims=mobile_claims,
                clock=lambda: clock[0], verified_at=clock[0])
        assert error.value.code == 'RECENT_LOGIN_REQUIRED'
    clock[0] += timedelta(minutes=5, seconds=1)
    with pytest.raises(AppError) as error:
        service.status(claims=claims)
    assert error.value.code == 'RECENT_LOGIN_REQUIRED'


@pytest.mark.parametrize('invalid', ['missing', 'replaced', 'expired', 'future_auth', 'old_proof'])
def test_wallet_admin_step_up_retains_transaction_guards(components, invalid):
    from sqlalchemy import delete, update
    from app.modules.identity.models import AdminSession
    from app.modules.identity.wallet_access import require_wallet_session
    factory, tokens, clock = components
    pair = tokens.issue_admin_pair(user_id='alice', display_name='Browser')
    claims = tokens.decode_access_token(pair.access_token)
    clock[0] += timedelta(minutes=6)
    tokens.step_up_admin(pair.access_token, 'correct password 123')
    with factory.begin() as session:
        if invalid == 'missing':
            session.execute(delete(AdminSession).where(AdminSession.user_id == 'alice'))
        elif invalid == 'replaced':
            session.execute(update(AdminSession).where(AdminSession.user_id == 'alice').values(family_id='different'))
        elif invalid == 'expired':
            session.execute(update(AdminSession).where(AdminSession.user_id == 'alice').values(expires_at=clock[0]))
        elif invalid == 'future_auth':
            session.execute(update(AdminSession).where(AdminSession.user_id == 'alice').values(authenticated_at=clock[0]+timedelta(seconds=1)))
    with factory.begin() as session:
        with pytest.raises(AppError) as error:
            require_wallet_session(session, claims=claims, clock=lambda: clock[0],
                verified_at=clock[0]-timedelta(seconds=31) if invalid == 'old_proof' else clock[0])
        assert error.value.code == {'future_auth':'RECENT_LOGIN_REQUIRED', 'old_proof':'TOTP_REQUIRED'}.get(invalid, 'ACCESS_TOKEN_INVALID')


def test_wallet_admin_deadline_rechecked_after_waiting_for_locks(components):
    from sqlalchemy import update
    from app.modules.identity.models import AdminSession
    from app.modules.identity.wallet_access import require_wallet_session
    factory, tokens, clock = components
    pair = tokens.issue_admin_pair(user_id='alice', display_name='Browser')
    claims = tokens.decode_access_token(pair.access_token)
    with factory.begin() as session:
        session.execute(update(AdminSession).where(AdminSession.user_id == 'alice')
            .values(expires_at=clock[0]+timedelta(seconds=1)))
    with factory.begin() as session:
        fresh = require_wallet_session(session, claims=claims,
            clock=lambda: clock[0], verified_at=clock[0])
        clock[0] += timedelta(seconds=1)
        with pytest.raises(AppError) as error:
            fresh()
        assert error.value.code == 'ACCESS_TOKEN_INVALID'


def test_step_up_preserves_family_deadline_and_refresh_replay_revokes(components):
    factory, tokens, clock = components
    pair = tokens.issue_admin_pair(user_id='alice', display_name='Browser')
    deadline = clock[0] + timedelta(hours=48)
    clock[0] += timedelta(minutes=6)
    with pytest.raises(AppError) as error:
        tokens.require_recent_login(pair.access_token)
    assert error.value.code == 'RECENT_LOGIN_REQUIRED'
    with pytest.raises(AppError):
        tokens.step_up_admin(pair.access_token, 'wrong')
    tokens.step_up_admin(pair.access_token, 'correct password 123')
    assert tokens.require_recent_login(pair.access_token)['family_id'] == pair.family_id
    assert tokens.admin_session(pair.access_token)['session_expires_at'] == deadline
    rotated = tokens.rotate_admin(pair.refresh_token)
    with pytest.raises(AppError) as error:
        tokens.rotate_admin(pair.refresh_token)
    assert error.value.code == 'REFRESH_TOKEN_REUSED'
    with pytest.raises(AppError):
        tokens.decode_access_token(rotated.access_token)


def test_non_admin_cannot_create_admin_session(components):
    factory, tokens, clock = components
    with factory.begin() as session:
        session.delete(session.get(UserRole, 'alice'))
    with pytest.raises(AppError) as error:
        tokens.issue_admin_pair(user_id='alice', display_name='Browser')
    assert error.value.code == 'PERMISSION_DENIED'


@pytest.mark.asyncio
async def test_http_cookie_origin_replacement_logout_and_ordinary_token_boundary(components, monkeypatch):
    from httpx import ASGITransport, AsyncClient
    from app.core.config import Settings
    from app.main import create_app
    factory, tokens, clock = components
    monkeypatch.setattr('app.modules.identity.login_captcha.LoginCaptcha.verify', lambda *args: None)
    app = create_app(Settings(_env_file=None, environment='test',
        jwt_secret='test-jwt-secret-at-least-thirty-two-bytes'), session_factory=factory)
    csrf = {'Origin': 'https://test', 'X-Admin-CSRF': '1'}
    body = dict(username='alice', password='correct password 123', device_key='browser',
        device_name='Browser', challenge_id='x' * 32, captcha_answer='ABCDEF')
    async with AsyncClient(transport=ASGITransport(app=app), base_url='https://test') as first, \
        AsyncClient(transport=ASGITransport(app=app), base_url='https://test') as second:
        assert (await first.post('/api/v1/auth/admin-login', json=body)).status_code == 403
        logged = await first.post('/api/v1/auth/admin-login', json=body, headers=csrf)
        assert logged.status_code == 200, logged.text
        assert 'refresh_token' not in logged.json()
        assert logged.json()['user_id'] == 'alice'
        assert logged.json()['session_id']
        assert logged.headers['cache-control'] == 'no-store'
        cookie = logged.headers['set-cookie']
        assert all(flag in cookie for flag in ['HttpOnly', 'Secure', 'SameSite=strict', 'Path=/api/v1/auth/admin-session'])
        bearer = {'Authorization': 'Bearer ' + logged.json()['access_token']}
        assert (await first.get('/api/v1/admin/context', headers=bearer)).status_code == 200
        mobile = tokens.issue_pair(user_id='alice', device_key='phone', display_name='Phone')
        ordinary = {'Authorization': 'Bearer ' + mobile.access_token}
        assert (await first.get('/api/v1/admin/context', headers=ordinary)).json()['error']['code'] == 'ADMIN_SESSION_REQUIRED'
        for path in ['/wallet/manual/payouts/x/claim', '/wallet/withdrawals/x/finance-approve', '/ledger/adjustments']:
            assert (await first.post('/api/v1' + path, headers=ordinary, json={})).status_code == 401
        denied = await first.post('/api/v1/auth/admin-session/refresh', headers={**csrf, 'Origin': 'https://evil.invalid'})
        assert denied.status_code == 403
        renewed = await first.post('/api/v1/auth/admin-session/refresh', headers=csrf)
        assert renewed.status_code == 200
        bearer = {'Authorization': 'Bearer ' + renewed.json()['access_token']}
        step = await first.post('/api/v1/auth/admin-session/step-up', json={'password': body['password']}, headers={**csrf, **bearer})
        assert step.status_code == 200, step.text
        assert step.json()['session_expires_at'] == logged.json()['session_expires_at']
        wrong = await second.post('/api/v1/auth/admin-login', json={**body, 'password': 'incorrect'}, headers=csrf)
        assert wrong.status_code == 401
        assert (await first.get('/api/v1/auth/admin-session', headers=bearer)).status_code == 200
        assert (await second.post('/api/v1/auth/admin-login', json=body, headers=csrf)).status_code == 200
        switched = await second.post('/api/v1/auth/admin-session/refresh',
            headers={**csrf, 'X-Admin-Session': logged.json()['session_id']})
        assert switched.json()['error']['code'] == 'ADMIN_SESSION_REPLACED'
        assert (await second.post('/api/v1/auth/admin-session/refresh', headers=csrf)).status_code == 200
        replaced = await first.get('/api/v1/admin/context', headers=bearer)
        assert replaced.json()['error']['code'] == 'ADMIN_SESSION_REPLACED'
        assert (await first.post('/api/v1/auth/admin-session/refresh', headers=csrf)).status_code == 401
        assert (await second.post('/api/v1/auth/admin-session/logout', headers=csrf)).status_code == 204
        assert (await second.post('/api/v1/auth/admin-session/refresh', headers=csrf)).status_code == 401
        assert tokens.decode_access_token(mobile.access_token)['sub'] == 'alice'
