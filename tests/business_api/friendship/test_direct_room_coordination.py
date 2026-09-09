from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone, timedelta
import os
from threading import Barrier
from uuid import uuid4

import pytest
from sqlalchemy import create_engine, event, select, text

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.main import create_app  # noqa: F401 - registers metadata
from app.modules.friendship.service import FriendshipService
from app.modules.identity.models import User
from app.modules.identity.enums import AccountStatus


class Profiles:
    def read_public_profiles(self, ids):
        return {user: object() for user in ids if user in {'alice', 'bob'}}


@pytest.fixture
def service(tmp_path):
    postgres_url = os.environ.get('DIRECT_ROOM_TEST_POSTGRES_URL')
    schema = f'pair_test_{uuid4().hex}'
    if postgres_url:
        # This opt-in target is a disposable local test cluster, never production.
        from sqlalchemy.engine import make_url
        target = make_url(postgres_url)
        assert target.host == '127.0.0.1' and target.port == 55439
        assert target.database == 'coordination_test'
        engine = create_engine(postgres_url)
        with engine.begin() as connection:
            connection.execute(text(f'CREATE SCHEMA {schema}'))
        engine = engine.execution_options(schema_translate_map={None: schema})
    else:
        engine = create_engine(f'sqlite+pysqlite:///{tmp_path / "pairs.db"}', connect_args={'timeout': 30})
        @event.listens_for(engine, 'connect')
        def enable_foreign_keys(connection, _):
            connection.execute('PRAGMA foreign_keys=ON')
    if postgres_url:
        # Profile access is mocked at the public boundary. A minimal synthetic
        # users table supplies only the FK target; unrelated identity metadata
        # has a SQLite-specific BOOLEAN DEFAULT 1 and is outside this test.
        with engine.begin() as connection:
            connection.execute(text(f'CREATE TABLE {schema}.users (id VARCHAR(36) PRIMARY KEY)'))
            connection.execute(text(f"INSERT INTO {schema}.users (id) VALUES ('alice'), ('bob')"))
        for name in ('direct_conversations', 'direct_room_reservations', 'audit_events',
                     'outbox_events', 'idempotency_records'):
            Base.metadata.tables[name].create(engine)
    else:
        Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    if not postgres_url:
        with factory.begin() as session:
            for user in ('alice', 'bob'):
                session.add(User(id=user, username=user, username_normalized=user,
                                 email=f'{user}@example.test', email_normalized=f'{user}@example.test',
                                 password_hash='test', status=AccountStatus.ACTIVE, created_at=now, updated_at=now))
    yield FriendshipService(factory, Profiles())
    if postgres_url:
        with engine.begin() as connection:
            connection.execute(text(f'DROP SCHEMA {schema} CASCADE'))
    engine.dispose()


def test_claim_replay_never_authorizes_second_creation(service):
    attempt = str(uuid4())
    assert service.claim_direct_conversation('alice', 'bob', attempt) == {
        'matrix_room_id': None, 'may_create': True, 'can_publish': True}
    assert service.claim_direct_conversation('alice', 'bob', attempt) == {
        'matrix_room_id': None, 'may_create': False, 'can_publish': True}
    assert service.claim_direct_conversation('bob', 'alice', str(uuid4())) == {
        'matrix_room_id': None, 'may_create': False, 'can_publish': False}


def test_opposite_concurrent_claims_grant_exactly_once(service):
    barrier = Barrier(8)
    def claim(i):
        barrier.wait()
        actor, peer = ('alice', 'bob') if i % 2 else ('bob', 'alice')
        return service.claim_direct_conversation(actor, peer, str(uuid4()))
    with ThreadPoolExecutor(max_workers=8) as executor:
        results = list(executor.map(claim, range(8)))
    assert sum(result['may_create'] for result in results) == 1


def test_publish_only_owner_and_immutable(service):
    attempt = str(uuid4())
    service.claim_direct_conversation('alice', 'bob', attempt)
    for actor, peer, key in [('bob', 'alice', attempt), ('alice', 'bob', str(uuid4()))]:
        with pytest.raises(AppError) as exc:
            service.publish_direct_conversation(actor, peer, key, '!wrong:example.test')
        assert exc.value.status_code == 409
    assert service.publish_direct_conversation('alice', 'bob', attempt, '!first:example.test') == {'matrix_room_id': '!first:example.test'}
    assert service.publish_direct_conversation('alice', 'bob', attempt, '!first:example.test') == {'matrix_room_id': '!first:example.test'}
    with pytest.raises(AppError):
        service.publish_direct_conversation('alice', 'bob', attempt, '!second:example.test')
    assert service.claim_direct_conversation('bob', 'alice', str(uuid4())) == {
        'matrix_room_id': '!first:example.test', 'may_create': False, 'can_publish': False}


def test_legacy_cannot_overwrite_or_bypass_pending(service):
    service.register_direct_conversation('alice', 'bob', '!old:example.test', 'old')
    assert service.register_direct_conversation('bob', 'alice', '!new:example.test', 'new') == {
        'matrix_room_id': '!old:example.test', 'existing': True}


def test_pending_blocks_legacy_and_does_not_expire(service):
    service.claim_direct_conversation('alice', 'bob', str(uuid4()))
    from app.modules.friendship.models import DirectRoomReservation
    with service.factory.begin() as session:
        reservation = session.scalar(select(DirectRoomReservation))
        reservation.created_at = datetime.now(timezone.utc) - timedelta(days=365)
    assert not service.claim_direct_conversation('bob', 'alice', str(uuid4()))['may_create']
    with pytest.raises(AppError) as exc:
        service.register_direct_conversation('alice', 'bob', '!bypass:example.test', 'legacy')
    assert exc.value.status_code == 409
    assert service.direct_conversation('alice', 'bob') == {'matrix_room_id': None}


def test_missing_peer_and_unclaimed_publish_fail_closed(service):
    with pytest.raises(AppError):
        service.claim_direct_conversation('alice', 'missing', str(uuid4()))
    with pytest.raises(AppError):
        service.publish_direct_conversation('alice', 'bob', str(uuid4()), '!orphan:example.test')
    assert service.claim_direct_conversation('alice', 'bob', str(uuid4()))['may_create']


def test_concurrent_legacy_registration_returns_one_immutable_room(service):
    barrier = Barrier(8)
    def register(i):
        barrier.wait()
        actor, peer = ('alice', 'bob') if i % 2 else ('bob', 'alice')
        return service.register_direct_conversation(actor, peer, f'!room{i}:example.test', f'legacy-{i}')
    with ThreadPoolExecutor(max_workers=8) as executor:
        results = list(executor.map(register, range(8)))
    assert len({result['matrix_room_id'] for result in results}) == 1
    assert sum(not result['existing'] for result in results) == 1


def test_existing_pre_migration_room_is_adopted(service):
    from app.modules.friendship.models import DirectConversation
    with service.factory.begin() as session:
        session.add(DirectConversation(id=str(uuid4()), user_low_id='alice', user_high_id='bob',
                                       matrix_room_id='!old:example.test', created_at=datetime.now(timezone.utc)))
    assert service.claim_direct_conversation('alice', 'bob', str(uuid4())) == {
        'matrix_room_id': '!old:example.test', 'may_create': False, 'can_publish': False}


def test_claim_racing_legacy_cannot_authorize_and_register_different_room(service):
    barrier = Barrier(2)
    def claim():
        barrier.wait()
        return service.claim_direct_conversation('alice', 'bob', str(uuid4()))
    def register():
        barrier.wait()
        try:
            return service.register_direct_conversation('bob', 'alice', '!legacy:example.test', 'legacy')
        except AppError as error:
            assert error.code == 'DIRECT_ROOM_PENDING'
            return None
    with ThreadPoolExecutor(max_workers=2) as executor:
        future = executor.submit(claim)
        registration = executor.submit(register).result()
        claimed = future.result()
    if claimed['may_create']:
        assert registration is None
    else:
        assert claimed['matrix_room_id'] == registration['matrix_room_id'] == '!legacy:example.test'
