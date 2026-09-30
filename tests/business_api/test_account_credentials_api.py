import pytest
import time
from httpx import ASGITransport, AsyncClient
from fastapi import FastAPI
from app.api.identity import create_identity_router
from app.core.config import Settings
from app.core.errors import install_error_handlers
from app.core.rate_limits import NoopRateLimiter
from app.modules.identity.tokens import TokenService
from test_account_credentials import env, email_code, deliver_phone


@pytest.fixture
def api(env):
    settings = Settings(_env_file=None, environment='test', database_url='sqlite+pysqlite:///:memory:',
        redis_url='redis://localhost:6379/15', jwt_secret='test-jwt-secret-at-least-thirty-two-bytes',
        email_verification_secret='test-email-code-secret', password_reset_secret='test-reset-secret',
        otp_hash_secret='test-otp-secret', phone_auth_enabled=True)
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(create_identity_router(settings, env[0], rate_limiter=NoopRateLimiter(), matrix_gateway=None, sms_sender=env[4]), prefix='/api/v1')
    return app, settings


@pytest.mark.asyncio
async def test_verify_uniform_window_and_late_worker_is_rollback_only(api, env, monkeypatch):
    import app.api.identity as module
    from app.modules.identity.account_credentials import AccountCredentialsService
    monkeypatch.setattr(module, 'PASSWORD_VERIFY_WINDOW_SECONDS', .12)
    monkeypatch.setattr(module, 'PASSWORD_VERIFY_WORK_SECONDS', .07)
    original = AccountCredentialsService.verify_password_code
    def slow(self, **kwargs):
        time.sleep(.09)
        return original(self, **kwargs)
    monkeypatch.setattr(AccountCredentialsService, 'verify_password_code', slow)
    async with AsyncClient(transport=ASGITransport(app=api[0]), base_url='http://test') as client:
        results = []
        for target in ('alice@example.test', 'nobody@example.test'):
            start = time.monotonic()
            result = await client.post('/api/v1/auth/password/code/verify', json={'channel':'email', 'target':target, 'code':'111111'})
            elapsed = time.monotonic() - start
            assert .11 <= elapsed < .5
            assert result.status_code == 400
            results.append(result.json())
        assert results[0] == results[1]


@pytest.mark.asyncio
@pytest.mark.parametrize('scenario', ['unknown', 'email_wrong', 'email_success', 'phone_wrong', 'phone_fault', 'phone_late_true', 'phone_late_false', 'phone_late_fault'])
async def test_all_verify_outcomes_share_window_without_blocking_event_loop(api, env, monkeypatch, scenario):
    import asyncio
    import app.api.identity as module
    from app.modules.identity.phone import PhoneOtpService
    from app.modules.identity.models import OtpChallenge
    from sqlalchemy import select
    monkeypatch.setattr(module, 'PASSWORD_VERIFY_WINDOW_SECONDS', .15)
    monkeypatch.setattr(module, 'PASSWORD_VERIFY_WORK_SECONDS', .09)
    channel = 'phone' if scenario.startswith('phone') else 'email'
    target = '13800000001' if channel == 'phone' else 'alice@example.test'
    if scenario == 'unknown': target = 'nobody@example.test'
    async with AsyncClient(transport=ASGITransport(app=api[0]), base_url='http://test') as client:
        await client.post('/api/v1/auth/password/code/request', json={'channel':channel, 'target':target})
        code = '111111'
        if scenario != 'unknown':
            correct = deliver_phone(env) if channel == 'phone' else email_code(env, 'password_reset_email')
            code = correct if scenario == 'email_success' else ('111111' if correct != '111111' else '222222')
        original = PhoneOtpService.verify_code
        def verify(self, **kwargs):
            if channel == 'phone':
                def provider(*args):
                    if 'late' in scenario: time.sleep(.11)
                    if 'fault' in scenario: raise RuntimeError('fake provider unavailable')
                    return scenario == 'phone_late_true'
                self.code_verifier = provider
            return original(self, **kwargs)
        monkeypatch.setattr(PhoneOtpService, 'verify_code', verify)
        ticks = []
        async def heartbeat():
            for _ in range(15):
                ticks.append(time.monotonic())
                await asyncio.sleep(.01)
        pulse = asyncio.create_task(heartbeat())
        start = time.monotonic()
        result = await client.post('/api/v1/auth/password/code/verify', json={'channel':channel, 'target':target, 'code':code})
        assert .14 <= time.monotonic() - start < .6
        await pulse
        assert len(ticks) == 15 and max(b-a for a,b in zip(ticks,ticks[1:])) < .07
        if scenario == 'email_success': assert result.status_code == 200
        else:
            assert result.status_code == 400
            assert result.json()['error'] == {'code':'PASSWORD_RESET_INVALID', 'message':'验证信息无效或已过期', 'fields':[], 'trace_id':'unknown'}
        if 'late' in scenario or scenario == 'phone_fault':
            with env[0]() as session:
                otp = session.scalar(select(OtpChallenge).where(OtpChallenge.purpose == 'password_reset_phone'))
                assert otp.consumed_at is None and otp.attempts_left == 5
                assert session.scalar(select(OtpChallenge).where(OtpChallenge.purpose == 'password_reset_grant')) is None


@pytest.mark.asyncio
async def test_verify_redis_limiter_does_not_block_other_requests(api, monkeypatch):
    import asyncio
    import app.api.identity as module
    monkeypatch.setattr(module, 'PASSWORD_VERIFY_WINDOW_SECONDS', .1)
    monkeypatch.setattr(module, 'PASSWORD_VERIFY_WORK_SECONDS', .07)
    monkeypatch.setattr(NoopRateLimiter, 'hit', lambda *args, **kwargs: time.sleep(.12))
    async with AsyncClient(transport=ASGITransport(app=api[0]), base_url='http://test') as client:
        ticks = []
        async def heartbeat():
            for _ in range(30):
                ticks.append(time.monotonic())
                await asyncio.sleep(.01)
        pulse = asyncio.create_task(heartbeat())
        result = await client.post('/api/v1/auth/password/code/verify', json={'channel':'email', 'target':'nobody@example.test', 'code':'111111'})
        await pulse
        assert max(b-a for a,b in zip(ticks,ticks[1:])) < .09
        assert result.status_code == 400


@pytest.mark.asyncio
async def test_api_recovery_two_real_steps_and_invalid_optional_auth(api, env):
    app, settings = api
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        body = {'channel': 'email', 'target': 'alice@example.test'}
        response = await client.post('/api/v1/auth/password/code/request', json=body)
        assert response.status_code == 202, response.text
        invalid = await client.post('/api/v1/auth/password/code/request', json=body, headers={'Authorization': 'Bearer invalid'})
        assert invalid.status_code == 401
        verified = await client.post('/api/v1/auth/password/code/verify', json={**body, 'code': email_code(env, 'password_reset_email')})
        assert verified.status_code == 200, verified.text
        response = await client.post('/api/v1/auth/password/code/reset', json={'token': verified.json()['reset_token'], 'new_password': 'new-password-123'})
        assert response.status_code == 204, response.text


@pytest.mark.asyncio
async def test_summary_requires_auth_and_masks_both_contacts(api, env):
    app, settings = api
    token = TokenService(env[0], jwt_secret=settings.jwt_secret, jwt_issuer=settings.jwt_issuer).issue_pair(
        user_id='alice', password='old-password-123', device_key='test', display_name='test').access_token
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        assert (await client.get('/api/v1/auth/account-security')).status_code == 401
        response = await client.get('/api/v1/auth/account-security', headers={'Authorization': 'Bearer ' + token})
        assert response.status_code == 200, response.text
        assert response.json()['email_verified'] and response.json()['phone_verified']
        assert 'alice@example.test' not in response.text and '13800000001' not in response.text


@pytest.mark.asyncio
async def test_public_invalid_verify_responses_do_not_enumerate_bound_accounts(api, env):
    app, settings = api
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        await client.post('/api/v1/auth/password/code/request', json={'channel': 'email', 'target': 'alice@example.test'})
        responses = []
        bad_code = '111111' if email_code(env, 'password_reset_email') != '111111' else '222222'
        for target in ('alice@example.test', 'bob@example.test', 'nobody@example.test'):
            response = await client.post('/api/v1/auth/password/code/verify', json={'channel': 'email', 'target': target, 'code': bad_code})
            assert response.status_code == 400
            responses.append(response.json())
        assert responses[0] == responses[1] == responses[2]


@pytest.mark.asyncio
async def test_email_binding_routes_complete_real_old_and_new_verification(api, env):
    app, settings = api
    token = TokenService(env[0], jwt_secret=settings.jwt_secret, jwt_issuer=settings.jwt_issuer).issue_pair(
        user_id='alice', device_key='test', display_name='test').access_token
    headers = {'Authorization': 'Bearer ' + token}
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        old = await client.post('/api/v1/auth/email/rebind/old-request', headers=headers, json={})
        assert old.status_code == 202 and old.json()['target'] != 'alice@example.test'
        confirmed = await client.post('/api/v1/auth/email/rebind/old-confirm', headers=headers, json={'code': email_code(env, 'email_bind_old_email')})
        assert confirmed.json() == {'verified': True}
        requested = await client.post('/api/v1/auth/email/rebind/new-request', headers=headers, json={'email': 'new@example.test'})
        assert requested.status_code == 202
        confirmed = await client.post('/api/v1/auth/email/rebind/confirm', headers=headers, json={'new_email': 'new@example.test', 'code': email_code(env, 'email_bind_new')})
        assert confirmed.status_code == 200 and confirmed.json()['email'] != 'new@example.test'
        summary = await client.get('/api/v1/auth/account-security', headers=headers)
        assert summary.json()['masked_email'] == confirmed.json()['email']
