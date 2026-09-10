"""Real PostgreSQL proof; uses an explicitly supplied isolated test database."""
import os
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from threading import Barrier, Event
from uuid import uuid4
from pathlib import Path
import runpy

import pytest
from sqlalchemy import create_engine, select, text

from app.core.database import create_session_factory
from app.core.errors import AppError
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import AdminSession, Device, RefreshToken, RefreshTokenFamily, User
from app.modules.identity.tokens import TokenService

pytestmark = pytest.mark.skipif(not os.getenv('MOBILE_AUTH_TEST_PG_URL'),
    reason='requires isolated MOBILE_AUTH_TEST_PG_URL')


@pytest.fixture
def pg_mobile():
    schema = 'mobile_auth_' + uuid4().hex
    engine = create_engine(os.environ['MOBILE_AUTH_TEST_PG_URL'])
    with engine.begin() as conn:
        conn.execute(text(f'CREATE SCHEMA {schema}'))
    scoped = create_engine(os.environ['MOBILE_AUTH_TEST_PG_URL'],
        connect_args={'options': f'-csearch_path={schema}'})
    for model in [User, Device, RefreshTokenFamily, RefreshToken, AdminSession]:
        model.__table__.create(scoped)
    factory = create_session_factory(scoped)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(User(id='alice', username='alice', username_normalized='alice',
            email='alice@example.invalid', email_normalized='alice@example.invalid',
            password_hash='unused', status=AccountStatus.ACTIVE, created_at=now, updated_at=now))
    def service():
        return TokenService(factory, jwt_secret='test-jwt-secret-at-least-thirty-two-bytes',
            jwt_issuer='liuhetong')
    yield factory, service
    scoped.dispose()
    with engine.begin() as conn:
        conn.execute(text(f'DROP SCHEMA {schema} CASCADE'))
    engine.dispose()


def test_concurrent_mobile_logins_leave_exactly_one_valid_family(pg_mobile):
    factory, service = pg_mobile
    barrier = Barrier(4)
    def login(index):
        barrier.wait()
        return service().issue_pair(user_id='alice', device_key=f'phone-{index}', display_name='Phone')
    with ThreadPoolExecutor(4) as pool:
        pairs = list(pool.map(login, range(4)))
    with factory() as session:
        active = list(session.scalars(select(RefreshTokenFamily).where(RefreshTokenFamily.revoked_at.is_(None))))
        assert len(active) == 1
    accepted = 0
    for pair in pairs:
        try:
            service().decode_access_token(pair.access_token)
            accepted += 1
        except AppError as error:
            assert error.code == 'SESSION_REPLACED'
    assert accepted == 1


def test_broker_grant_consumes_once_and_holds_user_lock_through_synapse(pg_mobile):
    from app.modules.identity.models import MatrixLoginGrant, MatrixLoginGeneration, MobileMatrixSession
    from app.modules.identity.matrix_login import MatrixLoginTokenService
    factory, tokens = pg_mobile
    from app.modules.audit.models import AuditEvent
    for model in [MatrixLoginGrant, MatrixLoginGeneration, MobileMatrixSession, AuditEvent]:
        model.__table__.create(factory.kw['bind'])
    with factory.begin() as session:
        session.get(User, 'alice').matrix_user_id = '@alice:matrix.test'
    pair = tokens().issue_pair(user_id='alice', device_key='old', display_name='old')
    entered, release, replacement_done = Event(), Event(), Event()
    class Gateway:
        calls = 0
        def complete_mobile_login(self, *, matrix_user_id, device_id, generation, display_name):
            self.calls += 1
            entered.set()
            assert release.wait(5)
            return {'user_id': matrix_user_id, 'device_id': device_id, 'access_token': 'memory-only'}
    gateway = Gateway()
    broker = MatrixLoginTokenService(factory, gateway=gateway, public_homeserver_url='https://matrix.test', expires_in=60)
    grant = broker.issue('alice', family_id=pair.family_id)
    def replace():
        result = tokens().issue_pair(user_id='alice', device_key='new', display_name='new')
        replacement_done.set()
        return result
    with ThreadPoolExecutor(2) as pool:
        first = pool.submit(broker.consume, {'type':'m.login.token','token':grant.login_token,'device_id':'D'})
        assert entered.wait(5)
        replacement = pool.submit(replace)
        try:
            assert not replacement_done.wait(.2)
        finally:
            release.set()
        assert first.result()['device_id'] == 'D'
        replacement.result()
    with pytest.raises(AppError):
        broker.consume({'type':'m.login.token','token':grant.login_token,'device_id':'D'})
    assert gateway.calls == 1


def test_refresh_racing_mobile_login_cannot_restore_old_family(pg_mobile):
    factory, service = pg_mobile
    old = service().issue_pair(user_id='alice', device_key='old', display_name='Old')
    barrier = Barrier(2)
    def refresh():
        barrier.wait()
        try:
            return service().rotate(old.refresh_token)
        except AppError as error:
            assert error.code == 'SESSION_REPLACED'
    def login():
        barrier.wait()
        return service().issue_pair(user_id='alice', device_key='new', display_name='New')
    with ThreadPoolExecutor(2) as pool:
        refreshing = pool.submit(refresh)
        latest = pool.submit(login).result(timeout=20)
        refreshing.result(timeout=20)
    with factory() as session:
        active = list(session.scalars(select(RefreshTokenFamily).where(RefreshTokenFamily.revoked_at.is_(None))))
        assert [family.id for family in active] == [latest.family_id]


@pytest.mark.parametrize('operation', ['logout', 'device'])
def test_revocation_waits_for_matrix_binding_user_lock(pg_mobile, operation):
    factory, service = pg_mobile
    pair = service().issue_pair(user_id='alice', device_key='phone', display_name='Phone')
    started, completed = Event(), Event()
    def revoke():
        started.set()
        if operation == 'logout':
            service().revoke_by_refresh_token(pair.refresh_token)
        else:
            service().revoke_device(user_id='alice', device_id=pair.device_id)
        completed.set()
    with ThreadPoolExecutor(1) as pool:
        with factory.begin() as transaction:
            transaction.scalar(select(User).where(User.id == 'alice').with_for_update())
            result = pool.submit(revoke)
            assert started.wait(2)
            assert not completed.wait(0.2), 'revocation bypassed the binding/login user lock'
        result.result(timeout=10)
    assert completed.is_set()
    with pytest.raises(AppError):
        service().decode_access_token(pair.access_token)


def test_additive_migration_retains_binding_on_application_rollback(pg_mobile):
    from alembic.migration import MigrationContext
    from alembic.operations import Operations
    from app.modules.identity.models import MobileMatrixSession
    factory, service = pg_mobile
    pair = service().issue_pair(user_id='alice', device_key='phone', display_name='Phone')
    migration = runpy.run_path(str(Path(__file__).parents[3] /
        'services/business-api/migrations/versions/0061_mobile_matrix_session.py'))
    with factory.kw['bind'].begin() as connection:
        with Operations.context(MigrationContext.configure(connection)):
            migration['upgrade']()
            connection.execute(MobileMatrixSession.__table__.insert().values(
                user_id='alice', family_id=pair.family_id, matrix_device_id='PHONE',
                updated_at=datetime.now(timezone.utc)))
            with pytest.raises(RuntimeError, match='application rollback'):
                migration['downgrade']()
        assert connection.scalar(select(MobileMatrixSession.matrix_device_id)) == 'PHONE'


def test_broker_migration_retains_consumed_grants_and_generation(pg_mobile):
    from alembic.migration import MigrationContext
    from alembic.operations import Operations
    from app.modules.identity.models import MatrixLoginGrant, MatrixLoginGeneration
    factory, service = pg_mobile
    pair = service().issue_pair(user_id='alice', device_key='phone', display_name='Phone')
    migration = runpy.run_path(str(Path(__file__).parents[3] /
        'services/business-api/migrations/versions/0062_matrix_login_broker.py'))
    with factory.kw['bind'].begin() as connection:
        with Operations.context(MigrationContext.configure(connection)):
            migration['upgrade']()
            connection.execute(MatrixLoginGrant.__table__.insert().values(token_hash='a' * 64,
                user_id='alice', family_id=pair.family_id, expires_at=datetime.now(timezone.utc),
                consumed_at=datetime.now(timezone.utc)))
            connection.execute(MatrixLoginGeneration.__table__.insert().values(user_id='alice', generation=27))
            with pytest.raises(RuntimeError, match='application rollback'):
                migration['downgrade']()
        assert connection.scalar(select(MatrixLoginGeneration.generation)) == 27
        assert connection.scalar(select(MatrixLoginGrant.consumed_at)) is not None
