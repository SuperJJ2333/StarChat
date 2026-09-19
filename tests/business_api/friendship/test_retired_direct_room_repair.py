from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from uuid import uuid4

import httpx
import pytest
from sqlalchemy import delete, select

from app.core.errors import AppError
from app.core.idempotency import IdempotencyRecord
from app.core.outbox import OutboxEvent, OutboxPublisher
from app.integrations.matrix_admin import SynapseMatrixAdminGateway
from app.modules.audit.models import AuditEvent
from app.modules.friendship.models import DirectConversation, DirectConversationRoom, DirectRoomReservation, Friendship, UserBlock
from test_direct_room_coordination import service  # noqa: F401

OLD, TARGET = '!old:test', '!target:test'


class Evidence:
    def __init__(self):
        self.details = {'room_id': OLD, 'joined_members': 0}
        self.states = {OLD: [], TARGET: [
            {'type': 'm.room.encryption', 'state_key': '', 'content': {'algorithm': 'm.megolm.v1.aes-sha2'}},
            *[{'type': 'm.room.member', 'state_key': f'@{u}:example.test', 'content': {'membership': 'join'}} for u in ('alice', 'bob')],
        ]}
        self.reads = []

    def get_room_details(self, room):
        self.reads.append(('details', room))
        return self.details

    def get_room_state_strict(self, room):
        self.reads.append(('state', room))
        return self.states[room]


@pytest.fixture
def repair(service):
    service.matrix_gateway = Evidence()
    now = datetime.now(timezone.utc)
    with service.factory.begin() as session:
        session.add(Friendship(id=str(uuid4()), user_low_id='alice', user_high_id='bob', created_at=now))
        session.add(DirectConversation(id='canonical', user_low_id='alice', user_high_id='bob', matrix_room_id=OLD, created_at=now))
        session.add(DirectConversationRoom(id=str(uuid4()), user_low_id='alice', user_high_id='bob', matrix_room_id=TARGET, created_at=now))
    return service


def invoke(service, **changes):
    args = dict(operator_id='operator-actual', actor='alice', peer='bob',
                expected_old_room_id=OLD, target_room_id=TARGET, idempotency_key='incident-123')
    args.update(changes)
    return service.repair_retired_direct_conversation(**args)


def counts(service):
    with service.factory() as session:
        return tuple(len(list(session.scalars(select(model)))) for model in
                     (AuditEvent, OutboxEvent, DirectConversationRoom, IdempotencyRecord))


def test_repair_preserves_identity_history_and_operator_audit(repair):
    result = invoke(repair)
    assert result == dict(conversation_id='canonical', matrix_room_id=TARGET, previous_room_id=OLD)
    assert repair.direct_conversation_associations('alice', 'bob')['room_ids'] == [OLD, TARGET]
    with repair.factory() as session:
        assert session.get(DirectConversation, 'canonical').matrix_room_id == TARGET
        audit = session.scalar(select(AuditEvent).where(AuditEvent.action == 'friend.direct_room_repaired'))
        assert audit.actor_id == 'operator-actual'
        assert audit.before_data['matrix_room_id'] == OLD
        assert audit.after_data['matrix_room_id'] == TARGET
        event = session.scalar(select(OutboxEvent).where(OutboxEvent.event_type == 'friend.direct_room_repaired'))
        assert event.payload['operator_id'] == 'operator-actual'
        assert event.payload['before']['matrix_room_id'] == OLD
        assert event.payload['after']['matrix_room_id'] == TARGET
    original = counts(repair)
    repair.matrix_gateway = None
    assert invoke(repair) == result
    assert counts(repair) == original
    with pytest.raises(AppError) as conflict:
        invoke(repair, target_room_id='!different:test')
    assert conflict.value.code == 'IDEMPOTENCY_KEY_REUSED'


@pytest.mark.parametrize('details', [None, {}, {'joined_members': 0},
    {'room_id': OLD, 'joined_members': False}, {'room_id': OLD, 'joined_members': '0'},
    {'room_id': OLD, 'joined_members': 0.0}, {'room_id': OLD, 'joined_members': -1},
    {'room_id': OLD, 'joined_members': 1}, {'room_id': '!other:test', 'joined_members': 0}])
def test_old_room_unknown_or_active_details_refuse(repair, details):
    repair.matrix_gateway.details = details
    before = counts(repair)
    with pytest.raises(AppError):
        invoke(repair)
    assert counts(repair) == before
    assert repair.direct_conversation('alice', 'bob')['matrix_room_id'] == OLD


@pytest.mark.parametrize('membership', ['join', 'invite', 'knock', 'ban', 'unknown', None])
def test_old_active_or_malformed_state_refuse(repair, membership):
    repair.matrix_gateway.states[OLD] = [{'type': 'm.room.member', 'state_key': '@alice:example.test', 'content': {'membership': membership}}]
    with pytest.raises(AppError):
        invoke(repair)


@pytest.mark.parametrize('membership', ['invite', 'leave', 'knock', 'ban'])
def test_target_requires_both_joined(repair, membership):
    repair.matrix_gateway.states[TARGET][1]['content']['membership'] = membership
    with pytest.raises(AppError):
        invoke(repair)


@pytest.mark.parametrize('failure', ['not_associated', 'not_friends', 'block_forward', 'block_reverse', 'unencrypted', 'extra_member', 'cas'])
def test_relationship_target_and_cas_refuse(repair, failure):
    with repair.factory.begin() as session:
        if failure == 'not_associated':
            session.execute(delete(DirectConversationRoom))
        if failure == 'not_friends':
            session.execute(delete(Friendship))
        if failure.startswith('block'):
            a, b = ('alice', 'bob') if failure == 'block_forward' else ('bob', 'alice')
            session.add(UserBlock(id=str(uuid4()), blocker_id=a, blocked_id=b, idempotency_key='block', created_at=datetime.now(timezone.utc)))
    if failure == 'unencrypted':
        repair.matrix_gateway.states[TARGET][0]['content']['algorithm'] = 'other'
    if failure == 'extra_member':
        repair.matrix_gateway.states[TARGET].append({'type': 'm.room.member', 'state_key': '@eve:test', 'content': {'membership': 'invite'}})
    with pytest.raises(AppError):
        invoke(repair, **({'expected_old_room_id': '!stale:test'} if failure == 'cas' else {}))
    # Inspect the failed operation directly: legacy GET now performs independent
    # safe auto-reconciliation and would intentionally repair the CAS fixture.
    with repair.factory() as session:
        assert session.get(DirectConversation, 'canonical').matrix_room_id == OLD


def test_concurrent_replay_changes_once(repair):
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(lambda _: invoke(repair), range(4)))
    assert all(row == results[0] for row in results)
    with repair.factory() as session:
        assert len(list(session.scalars(select(AuditEvent).where(AuditEvent.action == 'friend.direct_room_repaired')))) == 1
        assert len(list(session.scalars(select(IdempotencyRecord)))) == 1


def test_preserves_existing_reservation_and_new_key_cannot_adopt_success(repair):
    repair.claim_direct_conversation('alice', 'bob', 'original-attempt')
    with repair.factory() as session:
        old = session.scalar(select(DirectRoomReservation))
        reservation = (old.id, old.owner_id, old.attempt_id)
    invoke(repair)
    with repair.factory() as session:
        new = session.scalar(select(DirectRoomReservation))
        assert (new.id, new.owner_id, new.attempt_id) == reservation
    with pytest.raises(AppError) as rejected:
        invoke(repair, idempotency_key='another-key')
    assert rejected.value.code == 'DIRECT_ROOM_REPAIR_CONFLICT'


def test_corrupt_completed_replay_result_is_not_accepted(repair):
    invoke(repair)
    with repair.factory.begin() as session:
        record = session.scalar(select(IdempotencyRecord))
        record.response_body = {'matrix_room_id': '!unrelated:test'}
    with pytest.raises(AppError):
        invoke(repair)


def test_reversed_pair_replays_same_operation_without_writes(repair):
    original = invoke(repair)
    before = counts(repair)
    repair.matrix_gateway = None
    assert invoke(repair, actor='bob', peer='alice') == original
    assert counts(repair) == before


def test_outbox_failure_rolls_back_entire_repair(repair, monkeypatch):
    before = counts(repair)
    def fail(*args, **kwargs):
        raise RuntimeError('outbox unavailable')
    monkeypatch.setattr(OutboxPublisher, 'enqueue', fail)
    with pytest.raises(RuntimeError, match='outbox unavailable'):
        invoke(repair)
    assert counts(repair) == before
    with repair.factory() as session:
        assert session.get(DirectConversation, 'canonical').matrix_room_id == OLD
        assert session.scalar(select(DirectRoomReservation)) is None


def test_revalidates_matrix_after_pair_lock_acquired(repair, monkeypatch):
    from app.modules.friendship import direct_room_recovery
    original_lock = direct_room_recovery.lock_pair
    def acquire(*args):
        result = original_lock(*args)
        repair.matrix_gateway.states[TARGET][1]['content']['membership'] = 'leave'
        return result
    monkeypatch.setattr(direct_room_recovery, 'lock_pair', acquire)
    with pytest.raises(AppError):
        invoke(repair)
    assert repair.direct_conversation('alice', 'bob')['matrix_room_id'] == OLD


def test_concurrent_distinct_keys_use_cas_not_second_success(repair):
    def attempt(index):
        try:
            return invoke(repair, idempotency_key=f'repair-{index}')
        except AppError as error:
            return error.code
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(attempt, range(4)))
    assert sum(isinstance(row, dict) for row in results) == 1
    assert results.count('DIRECT_ROOM_REPAIR_CONFLICT') == 3


def test_block_appearing_during_matrix_evidence_is_rechecked(repair, monkeypatch):
    session_class = repair.factory.class_
    original_scalar = session_class.scalar
    def scalar(session, statement, *args, **kwargs):
        entities = [column.get('entity') for column in getattr(statement, 'column_descriptions', [])]
        if UserBlock in entities and ('state', OLD) in repair.matrix_gateway.reads:
            return 'concurrently-added-block'
        return original_scalar(session, statement, *args, **kwargs)
    monkeypatch.setattr(session_class, 'scalar', scalar)
    with pytest.raises(AppError) as rejected:
        invoke(repair)
    assert rejected.value.code == 'DIRECT_ROOM_REPAIR_FORBIDDEN'
    assert repair.direct_conversation('alice', 'bob')['matrix_room_id'] == OLD


@pytest.mark.parametrize('state', [None, {}, [None], [{'type': 'm.room.member'}],
    [{'type': 'm.room.member', 'state_key': '@a:test', 'content': {'membership': []}}]])
def test_malformed_old_state_fails_closed_with_domain_error(repair, state):
    repair.matrix_gateway.states[OLD] = state
    with pytest.raises(AppError):
        invoke(repair)


@pytest.mark.parametrize('status,body', [(404, {}), (200, {}), (200, {'state': None}),
    (200, {'state': [None]}), (200, {'state': [{'type': 'm.room.member'}]})])
def test_gateway_strict_state_rejects_missing_or_filtered_evidence(status, body):
    gateway = SynapseMatrixAdminGateway(homeserver_url='https://matrix.test', server_name='test', admin_access_token='test',
        client=httpx.Client(transport=httpx.MockTransport(lambda req: httpx.Response(status, json=body))))
    with pytest.raises(AppError):
        gateway.get_room_state_strict(OLD)


@pytest.mark.parametrize('status,body', [(404, {}), (503, {}), (200, {}),
    (200, {'room_id': OLD, 'joined_members': False}), (200, {'room_id': OLD, 'joined_members': '0'})])
def test_gateway_room_details_fail_closed(status, body):
    client = httpx.Client(transport=httpx.MockTransport(lambda req: httpx.Response(status, json=body)))
    gateway = SynapseMatrixAdminGateway(homeserver_url='https://matrix.test', server_name='test', admin_access_token='test', client=client)
    with pytest.raises(AppError):
        gateway.get_room_details(OLD)


def test_gateway_strict_metadata_reads_and_state_404_refusal():
    requests = []
    def transport(request):
        requests.append(request)
        if request.url.path.endswith('/state'):
            return httpx.Response(404, json={})
        return httpx.Response(200, json={'room_id': OLD, 'joined_members': 0})
    gateway = SynapseMatrixAdminGateway(homeserver_url='https://matrix.test', server_name='test', admin_access_token='test', client=httpx.Client(transport=httpx.MockTransport(transport)))
    assert gateway.get_room_details(OLD) == {'room_id': OLD, 'joined_members': 0}
    with pytest.raises(AppError):
        gateway.get_room_state_strict(OLD)
    assert all(request.method == 'GET' for request in requests)
