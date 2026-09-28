import pytest
from httpx import ASGITransport, AsyncClient

from app.core.config import Settings
from app.main import create_app
pytest_plugins = ('tests.business_api.identity.test_staff_activation',)


@pytest.mark.asyncio
async def test_staff_password_requires_bound_cookie_origin_and_csrf(env):
    factory, _, sender, activation = env
    challenge = activation.request(username='staff', password='correct password 123')
    activation.confirm(activation_id=challenge['activation_id'], code=sender.messages[-1][1])
    app = create_app(Settings(_env_file=None, environment='test',
        jwt_secret='test-jwt-secret-at-least-thirty-two-bytes'), session_factory=factory)
    csrf = {'Origin': 'https://test', 'X-Admin-CSRF': '1'}
    async with AsyncClient(transport=ASGITransport(app=app), base_url='https://test') as client:
        login = await client.post('/api/v1/auth/staff-login', headers=csrf,
            json={'username': 'staff', 'password': 'correct password 123'})
        assert login.status_code == 200, login.text
        bearer = {'Authorization': 'Bearer ' + login.json()['access_token']}
        path = '/api/v1/auth/admin-session/staff-password'
        body = {'current_password': 'correct password 123', 'new_password': 'new correct password 456'}
        assert (await client.post(path, headers=bearer, json=body)).status_code == 403
        assert (await client.post(path, headers={**csrf, **bearer, 'Origin': 'https://evil.invalid'}, json=body)).status_code == 403
        async with AsyncClient(transport=ASGITransport(app=app), base_url='https://test') as no_cookie:
            assert (await no_cookie.post(path, headers={**csrf, **bearer}, json=body)).status_code == 401
        assert (await client.post(path, headers={**csrf, **bearer}, json={**body, 'unexpected': True})).status_code == 422
        response = await client.post(path, headers={**csrf, **bearer}, json=body)
        assert response.status_code == 204, response.text
        assert response.headers['cache-control'] == 'no-store'
        assert (await client.get('/api/v1/auth/admin-session', headers=bearer)).status_code == 401


@pytest.mark.asyncio
async def test_staff_password_account_rate_limit_is_shared_across_source_ips(env):
    factory, _, sender, activation = env
    challenge = activation.request(username='staff', password='correct password 123')
    activation.confirm(activation_id=challenge['activation_id'], code=sender.messages[-1][1])
    keys = []

    class Limiter:
        def hit(self, key, *, limit, window_seconds):
            keys.append(key)

    app = create_app(Settings(_env_file=None, environment='test',
        jwt_secret='test-jwt-secret-at-least-thirty-two-bytes'), session_factory=factory,
        rate_limiter=Limiter())
    csrf = {'Origin': 'https://test', 'X-Admin-CSRF': '1'}
    path = '/api/v1/auth/admin-session/staff-password'
    body = {'current_password': 'wrong', 'new_password': 'new correct password 456'}
    for source in ('10.0.0.1', '10.0.0.2'):
        async with AsyncClient(transport=ASGITransport(app=app, client=(source, 1000)),
                base_url='https://test') as client:
            login = await client.post('/api/v1/auth/staff-login', headers=csrf,
                json={'username': 'staff', 'password': 'correct password 123'})
            assert login.status_code == 200, login.text
            bearer = {'Authorization': 'Bearer ' + login.json()['access_token']}
            async with AsyncClient(transport=ASGITransport(app=app, client=(source, 1000)),
                    base_url='https://test') as missing_cookie:
                assert (await missing_cookie.post(path, headers={**csrf, **bearer},
                    json=body)).status_code == 401
            response = await client.post(path, headers={**csrf, **bearer}, json=body)
            assert response.status_code == 401, response.text
    account_keys = [key for key in keys if key.startswith('auth:staff-password-user:')]
    assert len(account_keys) == 2 and account_keys[0] == account_keys[1]
    ip_keys = [key for key in keys if key.startswith('auth:staff-password-ip:')]
    assert len(ip_keys) == 4 and ip_keys[0] == ip_keys[1] and ip_keys[2] == ip_keys[3]


def test_staff_password_openapi_has_only_secret_input_fields(env):
    factory, _, _, _ = env
    app = create_app(Settings(_env_file=None, environment='test',
        jwt_secret='test-jwt-secret-at-least-thirty-two-bytes'), session_factory=factory)
    schema = app.openapi()
    route = schema['paths']['/api/v1/auth/admin-session/staff-password']['post']
    request_schema = route['requestBody']['content']['application/json']['schema']['$ref']
    model = schema['components']['schemas'][request_schema.rsplit('/', 1)[-1]]
    assert set(model['properties']) == {'current_password', 'new_password'}
    assert set(model['required']) == {'current_password', 'new_password'}
