"""PostgreSQL locks and indexed handle ownership, in a disposable isolated schema."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import os
from threading import Barrier, Event, local
from uuid import uuid4

import pytest
from sqlalchemy import create_engine, event, func, select, text

from app.core.database import create_session_factory
from app.core.errors import AppError
from app.core.idempotency import IdempotencyRecord
from app.core.outbox import OutboxEvent
from app.modules.audit.models import AuditEvent
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import EmailVerificationChallenge, Invitation, User, UsernameClaim
from app.modules.identity.username import UsernameService

pytestmark = pytest.mark.skipif(not os.getenv('MOBILE_AUTH_TEST_PG_URL'),
    reason='requires isolated MOBILE_AUTH_TEST_PG_URL')


@pytest.fixture
def pg_usernames():
    schema = 'username_' + uuid4().hex
    engine = create_engine(os.environ['MOBILE_AUTH_TEST_PG_URL'])
    with engine.begin() as connection:
        connection.execute(text(f'CREATE SCHEMA {schema}'))
    scoped = create_engine(os.environ['MOBILE_AUTH_TEST_PG_URL'], connect_args={'options': f'-csearch_path={schema}'})
    try:
        # Only this application's tables are required; test collection can
        # register unrelated modules on the shared Base metadata.
        for model in [User, UsernameClaim, Invitation, EmailVerificationChallenge,
                      IdempotencyRecord, AuditEvent, OutboxEvent]:
            model.__table__.create(scoped)
        factory = create_session_factory(scoped)
        now = datetime.now(timezone.utc)
        with factory.begin() as session:
            for owner in ['alice', 'bob']:
                session.add(User(id=owner, username=owner, username_normalized=owner,
                    email=None, email_normalized=None, status=AccountStatus.ACTIVE,
                    password_hash='not-used', matrix_user_id=f'@{owner}:matrix.test',
                    created_at=now, updated_at=now))
            session.flush()
            for owner in ['alice', 'bob']:
                session.add(UsernameClaim(normalized=owner, owner_user_id=owner, created_at=now))
        yield factory, scoped
    finally:
        scoped.dispose()
        with engine.begin() as connection:
            connection.execute(text(f'DROP SCHEMA {schema} CASCADE'))
        engine.dispose()


@pytest.mark.parametrize('scenario', ['same_name', 'same_account', 'same_operation'])
def test_concurrent_rename_is_atomic(pg_usernames, scenario):
    factory, _ = pg_usernames
    barrier = Barrier(2)
    def change(index):
        barrier.wait()
        owner = ('alice' if index == 0 else 'bob') if scenario == 'same_name' else 'alice'
        name = 'SharedName' if scenario in ['same_name', 'same_operation'] else ('AliceFirst' if index == 0 else 'AliceSecond')
        key = 'operation' if scenario == 'same_operation' else f'operation-{index}'
        try:
            return UsernameService(factory).change(owner, name, idempotency_key=key, trace_id='test', source_ip=None)
        except AppError as error:
            return error.code
    with ThreadPoolExecutor(2) as pool:
        results = list(pool.map(change, [0, 1]))
    success = [item for item in results if isinstance(item, dict)]
    assert len(success) == (2 if scenario == 'same_operation' else 1)
    if scenario == 'same_name':
        assert 'USERNAME_TAKEN' in results
    if scenario == 'same_account':
        assert 'USERNAME_CHANGE_COOLDOWN' in results
    if scenario == 'same_operation':
        assert results[0] == results[1]
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(AuditEvent).where(AuditEvent.action == 'identity.username.changed')) == 1
        assert session.scalar(select(func.count()).select_from(OutboxEvent).where(OutboxEvent.event_type == 'identity.profile.changed')) == 1
        assert session.scalar(select(func.count()).select_from(IdempotencyRecord).where(IdempotencyRecord.scope.like('identity.username.change:%'))) == 1
        for owner in ['alice', 'bob']:
            assert session.get(User, owner).matrix_user_id == f'@{owner}:matrix.test'


def test_availability_uses_primary_key_index(pg_usernames):
    _, engine = pg_usernames
    with engine.begin() as connection:
        # The tiny fixture would naturally choose a seq scan; disable it only
        # to verify that the exact equality lookup has a usable primary index.
        connection.execute(text('SET LOCAL enable_seqscan=off'))
        plan = '\n'.join(connection.execute(text("EXPLAIN SELECT owner_user_id FROM identity_username_claims WHERE normalized = 'alice'" )).scalars())
        assert 'Index Scan' in plan and 'identity_username_claims_pkey' in plan


def test_register_and_rename_share_handle_lock_order(pg_usernames):
    """Force the historical users/claims inverse lock order on real services."""
    from app.modules.identity.invitations import InvitationService
    from app.modules.identity.passwords import PasswordHasher
    from app.modules.identity.registration import RegistrationService, VerificationTokenCodec
    from datetime import timedelta
    factory, engine = pg_usernames
    invitations = InvitationService(factory)
    invitations.issue(code='RACE-REGISTER', max_uses=1,
        expires_at=datetime.now(timezone.utc) + timedelta(days=1), created_by='admin')
    registration = RegistrationService(factory, invitation_service=invitations,
        password_hasher=PasswordHasher(), token_codec=VerificationTokenCodec(b'test-email-verification-secret'))
    user_inserted, rename_claimed, registration_claim_attempted = Event(), Event(), Event()
    thread_state = local()

    def after_cursor(connection, cursor, statement, parameters, context, many):
        role = getattr(thread_state, 'role', None)
        sql = statement.lstrip().lower()
        if role == 'registration' and sql.startswith('insert into users '):
            user_inserted.set()
            # Before the fix, rename can claim the same handle while this
            # uncommitted user owns its users unique key. With a shared early
            # lock, rename waits and registration safely proceeds at timeout.
            rename_claimed.wait(timeout=0.75)
        if role == 'rename' and sql.startswith('insert into identity_username_claims ') and parameters.get('normalized') == 'raceshared':
            rename_claimed.set()
            registration_claim_attempted.wait(timeout=2)

    def before_cursor(connection, cursor, statement, parameters, context, many):
        if getattr(thread_state, 'role', None) == 'registration' and statement.lstrip().lower().startswith('insert into identity_username_claims '):
            registration_claim_attempted.set()

    event.listen(engine, 'after_cursor_execute', after_cursor)
    event.listen(engine, 'before_cursor_execute', before_cursor)
    def register():
        thread_state.role = 'registration'
        try:
            result = registration.register(username='RaceShared', email='race@example.test',
                password='correct horse battery staple', invitation_code='RACE-REGISTER',
                idempotency_key='registration-race')
            return {'registered': result.user_id}
        except AppError as error:
            return error.code
        except Exception as error:
            return 'unexpected:' + type(error).__name__

    def rename():
        thread_state.role = 'rename'
        assert user_inserted.wait(timeout=5)
        try:
            return UsernameService(factory).change('alice', 'RaceShared',
                idempotency_key='rename-race', trace_id='test', source_ip=None)
        except AppError as error:
            return error.code
        except Exception as error:
            return 'unexpected:' + type(error).__name__
    try:
        with ThreadPoolExecutor(2) as pool:
            registered = pool.submit(register)
            renamed = pool.submit(rename)
            results = [registered.result(timeout=15), renamed.result(timeout=15)]
    finally:
        event.remove(engine, 'after_cursor_execute', after_cursor)
        event.remove(engine, 'before_cursor_execute', before_cursor)
    assert len([item for item in results if isinstance(item, dict)]) == 1, results
    assert 'USERNAME_TAKEN' in results, results
    with factory() as session:
        current = session.scalar(select(User).where(User.username_normalized == 'raceshared'))
        assert current is not None
        assert session.get(UsernameClaim, 'raceshared').owner_user_id == current.id
        assert session.get(User, 'alice').matrix_user_id == '@alice:matrix.test'
