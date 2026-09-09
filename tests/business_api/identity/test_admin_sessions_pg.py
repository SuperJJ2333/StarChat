"""Isolated PostgreSQL evidence for cross-worker management session serialization."""
import os
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from threading import Barrier
from uuid import uuid4

import pytest
from sqlalchemy import create_engine, select, text

from app.core.database import create_session_factory
from app.core.errors import AppError
from app.modules.identity.enums import AccountStatus, RoleCode
from app.modules.identity.models import AdminSession, Device, RefreshToken, RefreshTokenFamily, User, UserRole
from app.modules.identity.tokens import TokenService


pytestmark = pytest.mark.skipif(not os.getenv('ADMIN_AUTH_TEST_PG_URL'),
    reason='requires explicitly configured isolated ADMIN_AUTH_TEST_PG_URL')


@pytest.fixture
def pg_tokens():
    schema = 'admin_auth_' + uuid4().hex
    engine = create_engine(os.environ['ADMIN_AUTH_TEST_PG_URL'])
    with engine.begin() as conn:
        conn.execute(text(f'CREATE SCHEMA {schema}'))
    scoped = create_engine(os.environ['ADMIN_AUTH_TEST_PG_URL'],
        connect_args={'options': f'-csearch_path={schema}'})
    for model in [User, Device, RefreshTokenFamily, RefreshToken, UserRole, AdminSession]:
        model.__table__.create(scoped)
    factory = create_session_factory(scoped)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(User(id='alice', username='alice', username_normalized='alice',
            email='alice@example.invalid', email_normalized='alice@example.invalid',
            password_hash='unused', status=AccountStatus.ACTIVE, created_at=now, updated_at=now))
        session.add(UserRole(id='role', user_id='alice', role_code=RoleCode.SUPER_ADMIN,
            assigned_by='alice', assigned_at=now))
    def service():
        return TokenService(factory, jwt_secret='test-jwt-secret-at-least-thirty-two-bytes',
            jwt_issuer='liuhetong')
    yield factory, service
    scoped.dispose()
    with engine.begin() as conn:
        conn.execute(text(f'DROP SCHEMA {schema} CASCADE'))
    engine.dispose()


def test_concurrent_logins_leave_one_current_family(pg_tokens):
    factory, service = pg_tokens
    barrier = Barrier(4)
    def login():
        barrier.wait()
        return service().issue_admin_pair(user_id='alice', display_name='Browser')
    with ThreadPoolExecutor(4) as pool:
        pairs = list(pool.map(lambda _: login(), range(4)))
    with factory() as session:
        active = list(session.scalars(select(RefreshTokenFamily).where(RefreshTokenFamily.revoked_at.is_(None))))
        assert len(active) == 1
        assert session.get(AdminSession, 'alice').family_id == active[0].id
    accepted = 0
    for pair in pairs:
        try:
            service().decode_access_token(pair.access_token)
            accepted += 1
        except AppError:
            pass
    assert accepted == 1


def test_concurrent_refresh_replay_revokes_family(pg_tokens):
    factory, service = pg_tokens
    pair = service().issue_admin_pair(user_id='alice', display_name='Browser')
    barrier = Barrier(2)
    def rotate():
        barrier.wait()
        try:
            return service().rotate_admin(pair.refresh_token)
        except AppError as error:
            return error.code
    with ThreadPoolExecutor(2) as pool:
        results = list(pool.map(lambda _: rotate(), range(2)))
    assert results.count('REFRESH_TOKEN_REUSED') == 1
    with factory() as session:
        assert session.get(RefreshTokenFamily, pair.family_id).revoke_reason == 'TOKEN_REUSE'


def test_login_racing_refresh_cannot_restore_replaced_family(pg_tokens):
    factory, service = pg_tokens
    old = service().issue_admin_pair(user_id='alice', display_name='Browser')
    barrier = Barrier(2)
    def login():
        barrier.wait()
        return service().issue_admin_pair(user_id='alice', display_name='New')
    def refresh():
        barrier.wait()
        try:
            return service().rotate_admin(old.refresh_token)
        except AppError:
            return None
    with ThreadPoolExecutor(2) as pool:
        login_future = pool.submit(login)
        refresh_future = pool.submit(refresh)
        new, refreshed = login_future.result(), refresh_future.result()
    assert service().decode_access_token(new.access_token)
    with pytest.raises(AppError):
        service().decode_access_token(old.access_token)
    if refreshed is not None:
        with pytest.raises(AppError):
            service().decode_access_token(refreshed.access_token)
