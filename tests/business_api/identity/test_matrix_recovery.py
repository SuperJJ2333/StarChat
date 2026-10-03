"""Real TokenService and SQLAlchemy identity authority, isolated synthetic accounts."""
from datetime import datetime, timezone
import os
import uuid

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from sqlalchemy import create_engine, text
from sqlalchemy.pool import StaticPool

from app.api.identity import create_identity_router
from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.modules.identity.enums import AccountStatus, RoleCode
from app.modules.identity.models import MobileMatrixSession, MatrixLoginGeneration, User, UserRole
from app.modules.identity.tokens import TokenService


@pytest.fixture(params=['sqlite', 'postgres'])
def authority(request):
    cleanup = None
    if request.param == 'postgres':
        dsn = os.environ.get('CHATFLOW_RECOVERY_TEST_DSN')
        if not dsn: pytest.skip('explicit isolated PostgreSQL DSN required')
        schema = 'task_3a_' + uuid.uuid4().hex
        cleanup = create_engine(dsn.replace('postgresql:', 'postgresql+psycopg:'))
        with cleanup.begin() as conn: conn.execute(text('CREATE SCHEMA ' + schema))
        engine = create_engine(dsn.replace('postgresql:', 'postgresql+psycopg:'),
                               connect_args={'options': '-csearch_path=' + schema})
    else:
        engine = create_engine('sqlite+pysqlite:///:memory:', poolclass=StaticPool,
                               connect_args={'check_same_thread': False})
    # Test collection may import unrelated financial metadata with SQLite-only
    # create_all defaults. This authority fixture owns only identity/audit/outbox.
    from app.modules.identity import models as identity_models
    from app.modules.audit.models import AuditEvent
    from app.core.outbox import OutboxEvent
    tables = {value.__table__ for value in vars(identity_models).values()
              if isinstance(value, type) and value.__module__ == identity_models.__name__
              and hasattr(value, '__table__')}
    tables.update((AuditEvent.__table__, OutboxEvent.__table__))
    Base.metadata.create_all(engine, tables=list(tables))
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(User(id='alice', username='alice', username_normalized='alice',
            email='alice@example.invalid', email_normalized='alice@example.invalid',
            password_hash='unused', status=AccountStatus.ACTIVE,
            matrix_user_id='@alice:test.invalid', created_at=now, updated_at=now))
        session.add(UserRole(id='staff', user_id='alice', role_code=RoleCode.SUPER_ADMIN,
                            assigned_by='alice', assigned_at=now))
    settings = Settings(_env_file=None, environment='test',
        database_url='sqlite+pysqlite:///:memory:', redis_url='redis://localhost:6379/15',
        jwt_secret='test-jwt-secret-at-least-thirty-two-bytes')
    tokens = TokenService(factory, jwt_secret=settings.jwt_secret, jwt_issuer=settings.jwt_issuer)
    pair = tokens.issue_pair(user_id='alice', device_key='phone', display_name='Phone')
    with factory.begin() as session:
        session.add(MobileMatrixSession(user_id='alice', family_id=pair.family_id,
                                       matrix_device_id='PHONE', updated_at=now))
        session.add(MatrixLoginGeneration(user_id='alice', generation=7))
    class Limiter:
        def hit(self, *args, **kwargs): pass
    app = FastAPI()
    from app.core.errors import AppError
    from fastapi.responses import JSONResponse
    @app.exception_handler(AppError)
    async def safe_error(request, exc):
        return JSONResponse({'code': exc.code}, status_code=exc.status_code)
    app.include_router(create_identity_router(settings, factory, Limiter(), matrix_gateway=None),
                       prefix='/api/v1')
    yield app, factory, tokens, pair
    engine.dispose()
    if cleanup:
        assert schema.startswith('task_3a_') and len(schema) == 40
        with cleanup.begin() as conn: conn.execute(text('DROP SCHEMA ' + schema + ' CASCADE'))
        cleanup.dispose()


async def call(app, token, **body):
    async with AsyncClient(transport=ASGITransport(app=app), base_url='https://test') as client:
        return await client.post('/api/v1/auth/matrix-recovery-authorize',
            headers={'Authorization': 'Bearer ' + token},
            json=body or {'matrix_user_id': '@alice:test.invalid', 'matrix_device_id': 'PHONE'})


@pytest.mark.asyncio
async def test_staff_role_own_mobile_family_gets_only_binding_metadata(authority):
    app, _, _, pair = authority
    response = await call(app, pair.access_token)
    assert response.status_code == 200
    assert response.headers['cache-control'] == 'no-store'
    assert response.json() == {'matrix_user_id': '@alice:test.invalid', 'matrix_device_id': 'PHONE',
                               'family_id': pair.family_id, 'generation': 7}


@pytest.mark.asyncio
@pytest.mark.parametrize('change', ['user', 'device', 'scope', 'replaced', 'suspended', 'binding', 'extra'])
async def test_authority_rejects_mismatch_or_revocation(authority, change):
    app, factory, tokens, pair = authority
    body = {'matrix_user_id': '@alice:test.invalid', 'matrix_device_id': 'PHONE'}
    token = pair.access_token
    if change == 'user': body['matrix_user_id'] = '@bob:test.invalid'
    if change == 'device': body['matrix_device_id'] = 'OTHER'
    if change == 'scope': token = tokens.issue_admin_pair(user_id='alice', display_name='Browser').access_token
    if change == 'replaced': tokens.issue_pair(user_id='alice', device_key='new', display_name='New')
    if change == 'suspended':
        with factory.begin() as session: session.get(User, 'alice').status = AccountStatus.SUSPENDED
    if change == 'binding':
        with factory.begin() as session: session.get(MobileMatrixSession, 'alice').matrix_device_id = 'NEW'
    if change == 'extra': body['session_key'] = 'must-never-be-accepted'
    response = await call(app, token, **body)
    assert response.status_code in (400, 401, 403, 409, 422)
    assert 'private_key' not in response.text


def test_authority_waiting_on_real_user_lock_observes_replacement(authority):
    import concurrent.futures
    import threading
    import time
    from sqlalchemy import select
    from app.core.errors import AppError
    from app.modules.identity.matrix_recovery import MatrixRecoveryAuthority
    _, factory, tokens, pair = authority
    with factory() as session:
        if session.bind.dialect.name != 'postgresql': pytest.skip('real PostgreSQL lock assertion')
    claims = tokens.decode_access_token(pair.access_token)
    started = threading.Event()
    def authorize():
        started.set()
        try:
            MatrixRecoveryAuthority(factory).authorize(claims,
                matrix_user_id='@alice:test.invalid', matrix_device_id='PHONE')
        except AppError as error: return error.code
        return 'unexpected-authorized'
    with concurrent.futures.ThreadPoolExecutor(1) as pool:
        with factory.begin() as session:
            session.scalar(select(User).where(User.id == 'alice').with_for_update())
            session.get(MobileMatrixSession, 'alice').matrix_device_id = 'REPLACED'
            future = pool.submit(authorize)
            assert started.wait(2)
            time.sleep(0.15)
            assert not future.done()
        assert future.result(timeout=5) == 'MATRIX_RECOVERY_FORBIDDEN'
