from datetime import timedelta

import pytest
from sqlalchemy import select

from app.core.errors import AppError
from app.modules.identity.enums import AccountStatus, RoleCode
from app.modules.identity.models import AdminSession, User, UserRole, OtpChallenge
from test_staff_activation import env


@pytest.mark.parametrize('channel', ['phone', 'email'])
def test_explicit_activation_channel_and_live_identity(env, channel):
    from app.modules.identity.staff_activation import require_staff_admin_access, require_pending_delivery
    factory, clock, sender, service = env
    with factory.begin() as session:
        user = session.get(User, 'staff')
        user.email_normalized = 'staff@example.invalid'
        user.email_verified_at = clock[0]
    result = service.request(username='staff', password='correct password 123', channel=channel)
    assert result['channel'] == channel
    with factory() as session:
        otp = session.scalar(select(OtpChallenge))
        require_pending_delivery(session, otp.id, clock[0])
    service.confirm(activation_id=result['activation_id'],
        code=sender.messages[-1][1] if channel == 'phone' else '846291')
    with factory() as session:
        require_staff_admin_access(session, session.get(User, 'staff'))
    with factory.begin() as session:
        user = session.get(User, 'staff')
        setattr(user, channel + '_verified_at', clock[0] + timedelta(seconds=1))
    with factory() as session, pytest.raises(AppError):
        require_staff_admin_access(session, session.get(User, 'staff'))


@pytest.mark.asyncio
async def test_staff_password_login_session_cookie_and_live_revocation(env, monkeypatch):
    from httpx import ASGITransport, AsyncClient
    from app.core.config import Settings
    from app.main import create_app
    factory, _, sender, service = env
    result = service.request(username='staff', password='correct password 123')
    service.confirm(activation_id=result['activation_id'], code=sender.messages[-1][1])
    def no_captcha(*args):
        raise AssertionError('Routine staff login must not call CAPTCHA')
    monkeypatch.setattr('app.modules.identity.login_captcha.LoginCaptcha.verify', no_captcha)
    app = create_app(Settings(_env_file=None, environment='test',
        jwt_secret='test-jwt-secret-at-least-thirty-two-bytes'), session_factory=factory)
    csrf = {'Origin': 'https://test', 'X-Admin-CSRF': '1'}
    body = {'username': 'staff', 'password': 'correct password 123'}
    path = '/api/v1/auth/staff-login'
    async with AsyncClient(transport=ASGITransport(app=app), base_url='https://test') as client:
        assert (await client.post(path, json=body)).status_code == 403
        assert (await client.post('/api/v1/auth/admin-login', json=body, headers=csrf)).status_code == 422
        assert (await client.post(path, json={**body, 'password': 'wrong'}, headers=csrf)).status_code == 401
        first = await client.post(path, json=body, headers=csrf)
        assert first.status_code == 200, first.text
        assert 'refresh_token' not in first.json()
        for expected in ['Secure', 'HttpOnly', 'SameSite=strict', 'Path=/api/v1/auth/admin-session']:
            assert expected in first.headers['set-cookie']
        assert first.headers['cache-control'] == 'no-store'
        second = await client.post(path, json=body, headers=csrf)
        assert second.status_code == 200, second.text
        assert second.json()['session_id'] != first.json()['session_id']
        check = '/api/v1/auth/admin-session'
        assert (await client.get(check, headers={'Authorization': 'Bearer '+first.json()['access_token']})).status_code == 401
        assert (await client.get(check, headers={'Authorization': 'Bearer '+second.json()['access_token']})).status_code == 200
        with factory.begin() as session:
            session.delete(session.get(UserRole, 'role'))
        assert (await client.get(check, headers={'Authorization': 'Bearer '+second.json()['access_token']})).status_code == 403


@pytest.mark.asyncio
async def test_staff_entry_session_cannot_gain_administrator_access_after_promotion(env, monkeypatch):
    from httpx import ASGITransport, AsyncClient
    from app.core.config import Settings
    from app.main import create_app

    factory, clock, sender, service = env
    activation = service.request(username='staff', password='correct password 123')
    service.confirm(activation_id=activation['activation_id'], code=sender.messages[-1][1])
    monkeypatch.setattr('app.modules.identity.login_captcha.LoginCaptcha.verify', lambda *args: None)
    app = create_app(Settings(_env_file=None, environment='test',
        jwt_secret='test-jwt-secret-at-least-thirty-two-bytes'), session_factory=factory)
    csrf = {'Origin': 'https://test', 'X-Admin-CSRF': '1'}
    async with AsyncClient(transport=ASGITransport(app=app), base_url='https://test') as client:
        logged = await client.post('/api/v1/auth/staff-login', headers=csrf,
            json={'username': 'staff', 'password': 'correct password 123'})
        assert logged.status_code == 200, logged.text
        staff_bearer = {'Authorization': 'Bearer ' + logged.json()['access_token']}
        with factory.begin() as session:
            session.add(UserRole(id='promoted-admin', user_id='staff', role_code=RoleCode.SUPER_ADMIN,
                assigned_by='external-admin', assigned_at=clock[0]))

        context = await client.get('/api/v1/admin/context', headers=staff_bearer)
        directory = await client.post('/api/v1/admin/users/search', headers={**csrf, **staff_bearer}, json={})
        refreshed = await client.post('/api/v1/auth/admin-session/refresh', headers=csrf)
        stepped_up = await client.post('/api/v1/auth/admin-session/step-up',
            headers={**csrf, **staff_bearer}, json={'password': 'correct password 123'})
        assert [r.status_code for r in (context, directory, refreshed, stepped_up)] == [401] * 4
        assert all(r.json()['error']['code'] == 'ADMIN_SESSION_REPLACED'
            for r in (context, directory, refreshed, stepped_up))

        admin = await client.post('/api/v1/auth/admin-login', headers=csrf,
            json={'username': 'staff', 'password': 'correct password 123',
                'device_key': 'browser', 'device_name': 'Browser',
                'challenge_id': 'x' * 32, 'captcha_answer': 'ABCDEF'})
        assert admin.status_code == 200, admin.text
        administrator_bearer = {'Authorization': 'Bearer ' + admin.json()['access_token']}
        assert (await client.get('/api/v1/admin/context', headers=administrator_bearer)).status_code == 200
        assert (await client.post('/api/v1/admin/users/search',
            headers={**csrf, **administrator_bearer}, json={})).status_code == 200


@pytest.mark.asyncio
async def test_staff_entry_session_can_refresh_while_role_is_unchanged(env):
    from httpx import ASGITransport, AsyncClient
    from app.core.config import Settings
    from app.main import create_app

    factory, _, sender, service = env
    activation = service.request(username='staff', password='correct password 123')
    service.confirm(activation_id=activation['activation_id'], code=sender.messages[-1][1])
    app = create_app(Settings(_env_file=None, environment='test',
        jwt_secret='test-jwt-secret-at-least-thirty-two-bytes'), session_factory=factory)
    csrf = {'Origin': 'https://test', 'X-Admin-CSRF': '1'}
    async with AsyncClient(transport=ASGITransport(app=app), base_url='https://test') as client:
        logged = await client.post('/api/v1/auth/staff-login', headers=csrf,
            json={'username': 'staff', 'password': 'correct password 123'})
        assert logged.status_code == 200, logged.text
        renewed = await client.post('/api/v1/auth/admin-session/refresh', headers=csrf)
        assert renewed.status_code == 200, renewed.text
        assert (await client.get('/api/v1/auth/admin-session', headers={
            'Authorization': 'Bearer ' + renewed.json()['access_token']})).status_code == 200


def test_existing_unmarked_management_session_requires_login_again(env):
    from app.modules.identity.tokens import TokenService

    factory, _, sender, service = env
    activation = service.request(username='staff', password='correct password 123')
    service.confirm(activation_id=activation['activation_id'], code=sender.messages[-1][1])
    tokens = TokenService(factory, jwt_secret='test-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer='test')
    pair = tokens.issue_admin_pair(user_id='staff', display_name='Staff browser', staff_only=True)
    with factory.begin() as session:
        session.get(AdminSession, 'staff').entry_mode = None
    with pytest.raises(AppError) as access:
        tokens.decode_access_token(pair.access_token)
    assert access.value.code == 'ADMIN_SESSION_REPLACED'
    with pytest.raises(AppError) as refresh:
        tokens.rotate_admin(pair.refresh_token)
    assert refresh.value.code == 'ADMIN_SESSION_REPLACED'


@pytest.mark.asyncio
async def test_administrator_entry_session_expires_when_superadmin_role_is_removed(env, monkeypatch):
    from httpx import ASGITransport, AsyncClient
    from app.core.config import Settings
    from app.main import create_app

    factory, clock, sender, service = env
    activation = service.request(username='staff', password='correct password 123')
    service.confirm(activation_id=activation['activation_id'], code=sender.messages[-1][1])
    with factory.begin() as session:
        session.add(UserRole(id='temporary-admin', user_id='staff', role_code=RoleCode.SUPER_ADMIN,
            assigned_by='external-admin', assigned_at=clock[0]))
    monkeypatch.setattr('app.modules.identity.login_captcha.LoginCaptcha.verify', lambda *args: None)
    app = create_app(Settings(_env_file=None, environment='test',
        jwt_secret='test-jwt-secret-at-least-thirty-two-bytes'), session_factory=factory)
    csrf = {'Origin': 'https://test', 'X-Admin-CSRF': '1'}
    async with AsyncClient(transport=ASGITransport(app=app), base_url='https://test') as client:
        logged = await client.post('/api/v1/auth/admin-login', headers=csrf,
            json={'username': 'staff', 'password': 'correct password 123',
                'device_key': 'browser', 'device_name': 'Browser',
                'challenge_id': 'x' * 32, 'captcha_answer': 'ABCDEF'})
        assert logged.status_code == 200, logged.text
        with factory.begin() as session:
            session.delete(session.get(UserRole, 'temporary-admin'))
        bearer = {'Authorization': 'Bearer ' + logged.json()['access_token']}
        access = await client.get('/api/v1/auth/admin-session', headers=bearer)
        refresh = await client.post('/api/v1/auth/admin-session/refresh', headers=csrf)
        assert access.status_code == refresh.status_code == 401
        assert access.json()['error']['code'] == refresh.json()['error']['code'] == 'ADMIN_SESSION_REPLACED'


@pytest.mark.asyncio
async def test_activated_staff_cannot_use_administrator_login_with_valid_captcha(env, monkeypatch):
    from httpx import ASGITransport, AsyncClient
    from app.core.config import Settings
    from app.main import create_app
    factory, _, sender, service = env
    activation = service.request(username='staff', password='correct password 123')
    service.confirm(activation_id=activation['activation_id'], code=sender.messages[-1][1])
    monkeypatch.setattr('app.modules.identity.login_captcha.LoginCaptcha.verify', lambda *args: None)
    app = create_app(Settings(_env_file=None, environment='test',
        jwt_secret='test-jwt-secret-at-least-thirty-two-bytes'), session_factory=factory)
    async with AsyncClient(transport=ASGITransport(app=app), base_url='https://test') as client:
        response = await client.post('/api/v1/auth/admin-login',
            headers={'Origin': 'https://test', 'X-Admin-CSRF': '1'},
            json={'username': 'staff', 'password': 'correct password 123',
                'device_key': 'browser', 'device_name': 'Browser',
                'challenge_id': 'x' * 32, 'captcha_answer': 'ABCDEF'})
    assert response.status_code == 403, response.text
    assert 'PERMISSION_DENIED' in response.text


@pytest.mark.asyncio
@pytest.mark.parametrize('state', ['unactivated', 'superadmin', 'mixed_superadmin', 'supervisor', 'disabled', 'finance'])
async def test_staff_login_eligibility(env, state):
    from httpx import ASGITransport, AsyncClient
    from app.core.config import Settings
    from app.main import create_app
    factory, _, sender, service = env
    with factory.begin() as session:
        if state == 'finance': session.get(UserRole, 'role').role_code = RoleCode.FINANCE_SUPPORT
        if state == 'mixed_superadmin':
            session.add(UserRole(id='extra-admin', user_id='staff', role_code=RoleCode.SUPER_ADMIN,
                assigned_by='admin', assigned_at=env[1][0]))
    if state != 'unactivated':
        result = service.request(username='staff', password='correct password 123')
        service.confirm(activation_id=result['activation_id'], code=sender.messages[-1][1])
    with factory.begin() as session:
        if state == 'superadmin': session.get(UserRole, 'role').role_code = RoleCode.SUPER_ADMIN
        if state == 'supervisor': session.get(UserRole, 'role').role_code = RoleCode.SUPPORT_SUPERVISOR
        if state == 'disabled': session.get(User, 'staff').status = AccountStatus.PENDING_PHONE
    app = create_app(Settings(_env_file=None, environment='test',
        jwt_secret='test-jwt-secret-at-least-thirty-two-bytes'), session_factory=factory)
    async with AsyncClient(transport=ASGITransport(app=app), base_url='https://test') as client:
        response = await client.post('/api/v1/auth/staff-login',
            json={'username': 'staff', 'password': 'correct password 123'},
            headers={'Origin': 'https://test', 'X-Admin-CSRF': '1'})
        assert response.status_code == (200 if state == 'finance' else 401 if state == 'disabled' else 403), response.text


@pytest.mark.asyncio
async def test_supervisor_only_first_login_requires_activation(env):
    from httpx import ASGITransport, AsyncClient
    from app.core.config import Settings
    from app.main import create_app
    factory, _, sender, service = env
    with factory.begin() as session:
        session.get(UserRole, 'role').role_code = RoleCode.SUPPORT_SUPERVISOR
    app = create_app(Settings(_env_file=None, environment='test',
        jwt_secret='test-jwt-secret-at-least-thirty-two-bytes'), session_factory=factory)
    csrf = {'Origin': 'https://test', 'X-Admin-CSRF': '1'}
    body = {'username': 'staff', 'password': 'correct password 123'}
    async with AsyncClient(transport=ASGITransport(app=app), base_url='https://test') as client:
        first = await client.post('/api/v1/auth/staff-login', headers=csrf, json=body)
        assert first.status_code == 403 and 'STAFF_ACTIVATION_REQUIRED' in first.text
        challenge = service.request(username='staff', password=body['password'])
        service.confirm(activation_id=challenge['activation_id'], code=sender.messages[-1][1])
        second = await client.post('/api/v1/auth/staff-login', headers=csrf, json=body)
        assert second.status_code == 200, second.text


@pytest.mark.parametrize('change', ['contact', 'verification', 'role'])
def test_email_choice_pending_delivery_and_confirmation_revalidate(env, change):
    from app.modules.identity.staff_activation import require_pending_delivery
    factory, clock, _, service = env
    with factory.begin() as session:
        user = session.get(User, 'staff')
        user.email_normalized = 'staff@example.invalid'
        user.email_verified_at = clock[0]
    result = service.request(username='staff', password='correct password 123', channel='email')
    with factory.begin() as session:
        otp_id = session.scalar(select(OtpChallenge.id))
        if change == 'contact': session.get(User, 'staff').email_normalized = 'other@example.invalid'
        if change == 'verification': session.get(User, 'staff').email_verified_at = None
        if change == 'role': session.delete(session.get(UserRole, 'role'))
    with factory() as session, pytest.raises(AppError):
        require_pending_delivery(session, otp_id, clock[0])
    with pytest.raises(AppError):
        service.confirm(activation_id=result['activation_id'], code='846291')


def test_phone_choice_cannot_fall_back_to_email(env):
    factory, clock, _, service = env
    with factory.begin() as session:
        user = session.get(User, 'staff')
        user.phone_verified_at = None
        user.email_normalized = 'staff@example.invalid'
        user.email_verified_at = clock[0]
    with pytest.raises(AppError):
        service.request(username='staff', password='correct password 123', channel='phone')
    assert service.request(username='staff', password='correct password 123', channel='email')['channel'] == 'email'


@pytest.mark.asyncio
async def test_staff_login_password_budget_and_admin_captcha_preserved(env, monkeypatch):
    from httpx import ASGITransport, AsyncClient
    from app.core.config import Settings
    from app.main import create_app
    from types import SimpleNamespace
    factory, _, _, _ = env
    # Exercise real CAPTCHA validation against an empty test store, never live Redis.
    monkeypatch.setattr('app.api.identity.Redis', SimpleNamespace(from_url=lambda *args, **kwargs: SimpleNamespace(getdel=lambda key: None)))
    counts = {}
    class TestLimiter:
        def hit(self, key, *, limit, window_seconds):
            counts[key] = counts.get(key, 0) + 1
            if counts[key] > limit:
                raise AppError(code='RATE_LIMITED', message='test rate limit', status_code=429)
    app = create_app(Settings(_env_file=None, environment='test',
        jwt_secret='test-jwt-secret-at-least-thirty-two-bytes'), session_factory=factory, rate_limiter=TestLimiter())
    csrf = {'Origin': 'https://test', 'X-Admin-CSRF': '1'}
    async with AsyncClient(transport=ASGITransport(app=app), base_url='https://test') as client:
        response = await client.post('/api/v1/auth/admin-login', headers=csrf, json={
            'username': 'staff', 'password': 'correct password 123', 'device_key': 'browser',
            'device_name': 'Browser', 'challenge_id': 'x'*32, 'captcha_answer': 'wrong'})
        assert response.status_code != 200
        assert 'CAPTCHA' in response.text.upper()
        for attempt in range(11):
            response = await client.post('/api/v1/auth/staff-login', headers=csrf,
                json={'username': 'staff', 'password': 'wrong'})
            assert response.status_code == (429 if attempt == 10 else 401), response.text
