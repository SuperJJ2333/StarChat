from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import create_engine, update

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.modules.identity.enums import AccountStatus, HoldType, RoleCode
from app.modules.identity.models import SecurityHold, User, UserRole


@pytest.fixture
def context():
    engine = create_engine('sqlite+pysqlite:///:memory:')
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime(2026, 9, 7, tzinfo=timezone.utc)
    with factory.begin() as session:
        session.add(User(id='user', username='user', username_normalized='user',
            email='user@example.test', email_normalized='user@example.test', password_hash='unused',
            status=AccountStatus.ACTIVE, created_at=now, updated_at=now))
    yield factory, now
    engine.dispose()


def check(factory, now, **kwargs):
    from app.modules.identity.wallet_access import require_wallet_actor
    with factory.begin() as session:
        return require_wallet_actor(session, user_id='user', clock=lambda: now, **kwargs)


def test_active_user_allowed(context):
    factory, now = context
    assert check(factory, now) is None


@pytest.mark.parametrize('status', [s for s in AccountStatus if s != AccountStatus.ACTIVE])
def test_inactive_account_denied(context, status):
    factory, now = context
    with factory.begin() as session:
        session.get(User, 'user').status = status
    with pytest.raises(AppError) as error:
        check(factory, now)
    assert error.value.code == 'WALLET_ACCOUNT_UNAVAILABLE'


@pytest.mark.parametrize('start,end,denied', [(-1, 1, True), (0, 1, True), (-2, 0, False), (1, 2, False)])
def test_recovery_hold_time_boundary(context, start, end, denied):
    factory, now = context
    with factory.begin() as session:
        session.add(SecurityHold(id='hold', user_id='user', hold_type=HoldType.WITHDRAWAL,
            reason_code='PASSWORD_RESET', starts_at=now+timedelta(seconds=start),
            ends_at=now+timedelta(seconds=end), created_at=now))
    if denied:
        with pytest.raises(AppError) as error:
            check(factory, now)
        assert error.value.code == 'WALLET_RECOVERY_HOLD'
    else:
        check(factory, now)


@pytest.mark.parametrize('role', list(RoleCode))
def test_admin_uses_actual_role(context, role):
    factory, now = context
    with factory.begin() as session:
        session.add(UserRole(id='role', user_id='user', role_code=role, assigned_by='bootstrap', assigned_at=now))
    if role == RoleCode.SUPER_ADMIN:
        check(factory, now, administrator=True)
    else:
        with pytest.raises(AppError) as error:
            check(factory, now, administrator=True)
        assert error.value.code == 'PERMISSION_DENIED'


def test_missing_user_and_missing_admin_role_denied(context):
    factory, now = context
    from app.modules.identity.wallet_access import require_wallet_actor
    with factory.begin() as session:
        with pytest.raises(AppError):
            require_wallet_actor(session, user_id='missing', clock=lambda: now)
        with pytest.raises(AppError):
            require_wallet_actor(session, user_id='user', clock=lambda: now, administrator=True)


def test_guard_preserves_callers_transaction(context):
    factory, now = context
    from app.modules.identity.wallet_access import require_wallet_actor
    with pytest.raises(RuntimeError):
        with factory.begin() as session:
            session.get(User, 'user').nickname = 'rollback-me'
            require_wallet_actor(session, user_id='user', clock=lambda: now)
            raise RuntimeError('rollback')
    with factory() as session:
        assert session.get(User, 'user').nickname == 'user'


def test_naive_clock_denied(context):
    factory, now = context
    with pytest.raises(ValueError):
        check(factory, now.replace(tzinfo=None))


def test_cached_active_user_does_not_override_database_suspension(context):
    factory, now = context
    from app.modules.identity.wallet_access import require_wallet_actor
    with factory.begin() as session:
        cached = session.get(User, 'user')
        session.execute(update(User).where(User.id == 'user').values(status=AccountStatus.SUSPENDED),
            execution_options={'synchronize_session': False})
        assert cached.status == AccountStatus.ACTIVE
        with pytest.raises(AppError) as error:
            require_wallet_actor(session, user_id='user', clock=lambda: now)
        assert error.value.code == 'WALLET_ACCOUNT_UNAVAILABLE'


def test_cached_admin_role_does_not_override_database_demotion(context):
    factory, now = context
    from app.modules.identity.wallet_access import require_wallet_actor
    with factory.begin() as session:
        session.add(UserRole(id='role', user_id='user', role_code=RoleCode.SUPER_ADMIN,
            assigned_by='bootstrap', assigned_at=now))
    with factory.begin() as session:
        cached = session.get(UserRole, 'role')
        session.execute(update(UserRole).where(UserRole.id == 'role').values(role_code=RoleCode.USER),
            execution_options={'synchronize_session': False})
        assert cached.role_code == RoleCode.SUPER_ADMIN
        with pytest.raises(AppError) as error:
            require_wallet_actor(session, user_id='user', clock=lambda: now, administrator=True)
        assert error.value.code == 'PERMISSION_DENIED'


def test_clock_sampled_after_identity_lock_before_hold_query(context, monkeypatch):
    factory, before = context
    after = before + timedelta(seconds=2)
    from app.modules.identity.wallet_access import require_wallet_actor
    with factory.begin() as session:
        session.add(SecurityHold(id='hold', user_id='user', hold_type=HoldType.WITHDRAWAL,
            reason_code='PASSWORD_RESET', starts_at=before+timedelta(seconds=1),
            ends_at=after+timedelta(hours=24), created_at=before))
    with factory.begin() as session:
        acquired = False
        original = session.scalar
        def scalar(statement, *args, **kwargs):
            nonlocal acquired
            result = original(statement, *args, **kwargs)
            if 'users.status' in str(statement):
                acquired = True
            return result
        monkeypatch.setattr(session, 'scalar', scalar)
        def clock():
            assert acquired, 'clock must be sampled after locking the account'
            return after
        with pytest.raises(AppError) as error:
            require_wallet_actor(session, user_id='user', clock=clock)
        assert error.value.code == 'WALLET_RECOVERY_HOLD'
