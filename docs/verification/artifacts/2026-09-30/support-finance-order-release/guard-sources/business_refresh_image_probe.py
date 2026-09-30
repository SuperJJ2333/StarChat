"""Run inside the final image only, with no production network or credentials."""
import asyncio
import base64
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import sys


PROTOCOLS = {'api': 'mobile-refresh-recovery-v1', 'worker': 'worker-runtime-refresh-v1'}
EXPECTED_CHECKS = {
    'api': ['expired_access_then_refresh', 'safe_validation', 'same_result_no_expiry_extension',
        'business_access', 'superseded_result', 'logout_isolation_and_revocation',
        'mismatched_replay_revokes', 'legacy_rotation', 'admin_domain_and_cookie_boundary'],
    'worker': ['worker_runtime_imports', 'worker_event_wiring', 'worker_credential_event_boundary',
        'worker_t2_manual_source_advisory',
        'worker_refresh_same_result_no_expiry_extension', 'worker_refresh_superseded_result',
        'worker_refresh_mismatched_replay_revokes', 'worker_refresh_legacy_rotation'],
}


async def verify_api():
    sys.path.insert(0, '/opt/business-api')
    from httpx import ASGITransport, AsyncClient
    import jwt
    from sqlalchemy import create_engine, select
    from sqlalchemy.pool import StaticPool
    from app.core.config import Settings
    from app.core.database import Base, create_session_factory
    from app.main import create_app
    from app.modules.identity.enums import AccountStatus, RoleCode
    from app.modules.identity.models import User, UserRole, RefreshToken, RefreshTokenFamily
    from app.modules.identity.passwords import PasswordHasher
    from app.modules.identity.tokens import TokenService
    secret = 'isolated-protocol-gate-secret-at-least-thirty-two-bytes'
    settings = Settings(_env_file=None, environment='test',
        database_url='sqlite+pysqlite:///:memory:', redis_url='redis://127.0.0.1:6379/15',
        jwt_secret=secret, email_verification_secret='isolated-email-secret',
        password_reset_secret='isolated-reset-secret', avatar_storage_root='/tmp/probe-media')
    engine = create_engine(settings.database_url, connect_args={'check_same_thread': False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    password = 'isolated fixture password never used in production'
    with factory.begin() as session:
        session.add(User(id='protocol-fixture', username='protocolfixture', username_normalized='protocolfixture',
            email='protocol@example.invalid', email_normalized='protocol@example.invalid',
            password_hash=PasswordHasher().hash(password), status=AccountStatus.ACTIVE,
            email_verified_at=now, created_at=now, updated_at=now))
    app = create_app(settings, session_factory=factory)
    op = base64.urlsafe_b64encode(bytes(range(32))).decode().rstrip('=')
    other = base64.urlsafe_b64encode(bytes(range(1, 33))).decode().rstrip('=')
    checks = []
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://isolated') as client:
        async def login():
            response = await client.post('/api/v1/auth/login', json={'username':'protocolfixture',
                'password':password, 'device_key':'isolated-device', 'device_name':'Protocol gate'})
            assert response.status_code == 200, 'login'
            return response.json()
        async def refresh(token, operation=op):
            data = {'refresh_token':token}
            if operation is not None:
                data['operation_id'] = operation
            return await client.post('/api/v1/auth/refresh', json=data)
        pair = await login()
        # Real protected endpoint must reject an expired signed access token.
        claims = jwt.decode(pair['access_token'], secret, algorithms=['HS256'], options={'verify_aud':False})
        claims['exp'] = int((now-timedelta(seconds=1)).timestamp())
        expired = jwt.encode(claims, secret, algorithm='HS256')
        response = await client.get('/api/v1/moments/feed', headers={'Authorization':'Bearer '+expired})
        assert response.status_code == 401, 'expired_access'
        invalid = await refresh(pair['refresh_token'], 'invalid-private-fixture')
        assert invalid.status_code == 422 and 'invalid-private-fixture' not in invalid.text, 'validation'
        response = await refresh(pair['refresh_token'])
        assert response.status_code == 200, 'operation_contract'
        child = response.json()
        with factory() as s:
            before = [(r.id, r.expires_at) for r in s.scalars(select(RefreshToken))]
        retry = await refresh(pair['refresh_token'])
        assert retry.status_code == 200 and retry.json()['refresh_token'] == child['refresh_token'], 'same_result'
        with factory() as s:
            assert [(r.id,r.expires_at) for r in s.scalars(select(RefreshToken))] == before, 'expiry_extended'
        response = await client.get('/api/v1/moments/feed', headers={'Authorization':'Bearer '+child['access_token']})
        assert response.status_code == 200, 'business_access_after_refresh'
        checks += ['expired_access_then_refresh', 'safe_validation', 'same_result_no_expiry_extension', 'business_access']
        advanced = await refresh(child['refresh_token'], other)
        assert advanced.status_code == 200
        superseded = await refresh(pair['refresh_token'])
        assert superseded.status_code == 409 and superseded.json()['error']['code'] == 'REFRESH_RESULT_SUPERSEDED'
        logout_bad = await client.post('/api/v1/auth/logout', json={'refresh_token':advanced.json()['refresh_token'], 'operation_id':op})
        assert logout_bad.status_code == 422, 'logout_model_widened'
        logout = await client.post('/api/v1/auth/logout', json={'refresh_token':advanced.json()['refresh_token']})
        assert logout.status_code in (200, 204)
        assert (await refresh(child['refresh_token'], other)).status_code == 401, 'logout_revived'
        checks += ['superseded_result', 'logout_isolation_and_revocation']
        pair = await login()
        assert (await refresh(pair['refresh_token'])).status_code == 200
        replay = await refresh(pair['refresh_token'], other)
        assert replay.status_code == 401 and replay.json()['error']['code'] == 'REFRESH_TOKEN_REUSED'
        with factory() as s:
            assert any(f.revoke_reason == 'TOKEN_REUSE' for f in s.scalars(select(RefreshTokenFamily)))
        pair = await login()
        assert (await refresh(pair['refresh_token'], None)).status_code == 200
        assert (await refresh(pair['refresh_token'], None)).status_code == 401
        checks += ['mismatched_replay_revokes', 'legacy_rotation']
        with factory.begin() as session:
            session.add(UserRole(id='protocol-role',user_id='protocol-fixture',role_code=RoleCode.SUPER_ADMIN,
                assigned_by='protocol-fixture',assigned_at=now))
        tokens = TokenService(factory,jwt_secret=secret,jwt_issuer=settings.jwt_issuer)
        admin = tokens.issue_admin_pair(user_id='protocol-fixture',display_name='Isolated admin')
        assert (await refresh(admin.refresh_token)).status_code == 401, 'mobile_consumed_admin'
        headers = {'Origin':'http://isolated','X-Admin-CSRF':'1','X-Admin-Session':admin.family_id}
        forbidden = await client.post('/api/v1/auth/admin-session/refresh',headers=headers,
            json={'refresh_token':admin.refresh_token,'operation_id':op})
        assert forbidden.status_code == 401, 'body_bypassed_admin_cookie'
        headers['Cookie'] = '__Secure-starchat_admin_refresh='+admin.refresh_token
        standard = await client.post('/api/v1/auth/admin-session/refresh',headers=headers)
        assert standard.status_code == 200, 'admin_cookie_flow_changed'
        checks.append('admin_domain_and_cookie_boundary')
    engine.dispose()
    if checks != EXPECTED_CHECKS['api']:
        raise AssertionError('api proof incomplete')
    return {'protocol':PROTOCOLS['api'], 'role':'api', 'passed':True, 'checks':checks}


def verify_worker(worker_root='/opt/business-worker/app',
                  package_root='/usr/local/lib/python3.12/site-packages/app'):
    """Probe the imports used by the Worker entrypoint, not its stale API tree."""
    worker_root = Path(worker_root).resolve(strict=True)
    package_root = Path(package_root).resolve(strict=True)
    sys.path.insert(0, str(package_root.parent))
    sys.path.insert(0, str(worker_root))

    import app
    import main
    from app.core.database import Base, create_session_factory
    from app.core.errors import AppError
    from app.core.outbox import OutboxMessage
    from app.modules.identity.enums import AccountStatus
    from app.modules.identity.models import RefreshToken, RefreshTokenFamily, User
    from app.modules.identity.tokens import TokenService
    from app.integrations.tron.funding_source import FundingSourceError
    from sqlalchemy import create_engine, select
    from sqlalchemy.pool import StaticPool
    from tasks import identity
    from tasks import wallet_alert_email
    import app.modules.wallet.manual_reserve_monitor as reserve_module

    def origin(module, expected):
        if Path(module.__file__).resolve() != expected:
            raise AssertionError('worker import origin')

    origin(app, package_root / '__init__.py')
    origin(main, worker_root / 'main.py')
    origin(identity, worker_root / 'tasks' / 'identity.py')
    import app.modules.identity.tokens as token_module
    origin(token_module, package_root / 'modules' / 'identity' / 'tokens.py')
    origin(reserve_module, package_root / 'modules' / 'wallet' / 'manual_reserve_monitor.py')
    origin(wallet_alert_email, worker_root / 'tasks' / 'wallet_alert_email.py')
    checks = ['worker_runtime_imports']

    handlers = main.build_identity_handlers(session_factory=None,
        verification_secret='isolated-verification-secret',
        public_base_url='https://example.invalid', email_sender=object())
    handler = handlers.get('identity.account_credentials')
    if not isinstance(handler, identity.AccountCredentialsObservationTask):
        raise AssertionError('worker event wiring')
    checks.append('worker_event_wiring')
    safe = OutboxMessage('isolated-event', 'identity.account_credentials',
        'identity.password.reset', 'user', 'isolated-user',
        {'user_id':'isolated-user', 'reason_code':'PASSWORD_RESET'}, {}, 1)
    handler(safe)
    for payload in (
        {'user_id':'isolated-user', 'reason_code':'PASSWORD_RESET', 'password':'isolated'},
        {'user_id':'isolated-user', 'reason_code':'PASSWORD_RESET', 'email':'isolated@example.invalid'},
        {'user_id':'other', 'reason_code':'PASSWORD_RESET'},
        {'user_id':'isolated-user', 'reason_code':'EMAIL_BINDING'},
    ):
        unsafe = OutboxMessage('isolated-event', 'identity.account_credentials',
            'identity.password.reset', 'user', 'isolated-user', payload, {}, 1)
        try:
            handler(unsafe)
        except ValueError as error:
            if str(error) != 'ACCOUNT_CREDENTIALS_EVENT_INVALID':
                raise AssertionError('worker event rejection') from None
        else:
            raise AssertionError('worker accepted unsafe event')
    checks.append('worker_credential_event_boundary')

    observed = []
    class IsolatedIncidentSink:
        def observe_in_session(self, _session, incidents, *, actor_id, complete):
            observed.append((incidents, actor_id, complete))

    monitor = object.__new__(reserve_module.ManualReserveMonitor)
    monitor.incidents = IsolatedIncidentSink()
    monitor._heartbeat = lambda _session, _now, code: observed.append(('heartbeat', code))
    original_pause = reserve_module.apply_manual_pause
    def reject_pause(*_args, **_kwargs):
        raise AssertionError('T2 must not pause wallet')
    reserve_module.apply_manual_pause = reject_pause
    try:
        if (not reserve_module.ManualReserveMonitor._is_source_read_budget_expired(
                FundingSourceError('SOURCE_READ_BUDGET_EXPIRED')) or
                reserve_module.ManualReserveMonitor._is_source_read_budget_expired(
                    FundingSourceError('OTHER_SOURCE_FAILURE')) or
                reserve_module.ManualReserveMonitor._is_source_read_budget_expired(
                    ValueError('SOURCE_READ_BUDGET_EXPIRED'))):
            raise AssertionError('T2 source classification')
        blocked = monitor._block(object(), 'MANUAL_SOURCE_UNAVAILABLE',
                                 datetime.now(timezone.utc), source_read_timeout=True)
    finally:
        reserve_module.apply_manual_pause = original_pause
    if (blocked != {'complete':False, 'status':'BLOCKED',
                    'codes':['MANUAL_SOURCE_UNAVAILABLE']} or len(observed) != 2 or
            observed[0][0][0].get('severity') != 'T2' or
            observed[0][0][0].get('code') != 'MANUAL_SOURCE_UNAVAILABLE' or
            observed[0][2] is not False or observed[1] != ('heartbeat', 'MANUAL_SOURCE_UNAVAILABLE')):
        raise AssertionError('T2 advisory incident semantics')
    checks.append('worker_t2_manual_source_advisory')

    engine = create_engine('sqlite+pysqlite:///:memory:',
        connect_args={'check_same_thread':False}, poolclass=StaticPool)
    try:
        Base.metadata.create_all(engine)
        factory = create_session_factory(engine)
        now = datetime.now(timezone.utc)
        with factory.begin() as session:
            session.add(User(id='isolated-user', username='isolated',
                username_normalized='isolated', email='isolated@example.invalid',
                email_normalized='isolated@example.invalid', password_hash='isolated-only',
                status=AccountStatus.ACTIVE, email_verified_at=now,
                created_at=now, updated_at=now))
        tokens = TokenService(factory, jwt_secret='isolated-worker-gate-secret-over-thirty-two-bytes',
            jwt_issuer='isolated-worker-gate', now_factory=lambda: now)
        operation = base64.urlsafe_b64encode(bytes(range(32))).decode().rstrip('=')
        other = base64.urlsafe_b64encode(bytes(range(1, 33))).decode().rstrip('=')

        def issue():
            return tokens.issue_pair(user_id='isolated-user', device_key='isolated-device',
                display_name='Isolated device')

        def expect_code(call, code):
            try:
                call()
            except AppError as error:
                if error.code != code:
                    raise AssertionError('worker refresh error code') from None
            else:
                raise AssertionError('worker refresh accepted replay')

        parent = issue()
        child = tokens.rotate(parent.refresh_token, operation_id=operation)
        with factory() as session:
            before = [(record.id, record.expires_at) for record in session.scalars(select(RefreshToken))]
        retry = tokens.rotate(parent.refresh_token, operation_id=operation)
        if retry.refresh_token != child.refresh_token:
            raise AssertionError('worker refresh result changed')
        with factory() as session:
            after = [(record.id, record.expires_at) for record in session.scalars(select(RefreshToken))]
        if after != before:
            raise AssertionError('worker refresh expiry extended')
        checks.append('worker_refresh_same_result_no_expiry_extension')

        current = tokens.rotate(child.refresh_token, operation_id=other)
        expect_code(lambda: tokens.rotate(parent.refresh_token, operation_id=operation),
                    'REFRESH_RESULT_SUPERSEDED')
        with factory() as session:
            if session.get(RefreshTokenFamily, current.family_id).revoked_at is not None:
                raise AssertionError('worker refresh superseded family revoked')
        checks.append('worker_refresh_superseded_result')

        parent = issue()
        tokens.rotate(parent.refresh_token, operation_id=operation)
        expect_code(lambda: tokens.rotate(parent.refresh_token, operation_id=other),
                    'REFRESH_TOKEN_REUSED')
        with factory() as session:
            if session.get(RefreshTokenFamily, parent.family_id).revoke_reason != 'TOKEN_REUSE':
                raise AssertionError('worker refresh replay family not revoked')
        checks.append('worker_refresh_mismatched_replay_revokes')

        parent = issue()
        tokens.rotate(parent.refresh_token)
        expect_code(lambda: tokens.rotate(parent.refresh_token), 'REFRESH_TOKEN_REUSED')
        checks.append('worker_refresh_legacy_rotation')
    finally:
        engine.dispose()
    if checks != EXPECTED_CHECKS['worker']:
        raise AssertionError('worker proof incomplete')
    return {'protocol':PROTOCOLS['worker'], 'role':'worker', 'passed':True, 'checks':checks}


if __name__ == '__main__':
    try:
        role = os.environ['STARCHAT_PROTOCOL_ROLE']
        proof = asyncio.run(verify_api()) if role == 'api' else verify_worker() if role == 'worker' else None
        if proof is None:
            raise ValueError('unknown image role')
        print(json.dumps(proof))
    except Exception:
        # No traceback, response, token, credential hash or environment output.
        print(json.dumps({'passed':False}))
        sys.exit(1)
