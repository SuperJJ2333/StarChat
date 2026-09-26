"""Run inside the final image only, with no production network or credentials."""
import asyncio
import base64
from datetime import datetime, timedelta, timezone
import json
import sys

sys.path.insert(0, '/opt/business-api')


async def verify():
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
    return {'protocol':'mobile-refresh-recovery-v1', 'passed':True, 'checks':checks}


if __name__ == '__main__':
    try:
        print(json.dumps(asyncio.run(verify())))
    except Exception:
        # No traceback, response, token, credential hash or environment output.
        print(json.dumps({'protocol':'mobile-refresh-recovery-v1', 'passed':False}))
        sys.exit(1)
