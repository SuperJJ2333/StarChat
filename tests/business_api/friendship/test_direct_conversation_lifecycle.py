from concurrent.futures import ThreadPoolExecutor
from uuid import uuid4

import pytest
from sqlalchemy import delete, select

from app.core.errors import AppError
from app.modules.friendship.models import DirectConversation, DirectConversationRoom
from test_retired_direct_room_repair import repair, service, OLD, TARGET  # noqa: F401


def resolve(service):
    return service.resolve_direct_conversation('alice', 'bob', str(uuid4()))


def test_retired_source_automatically_reconciles_and_retains_identity(repair):
    result = resolve(repair)
    assert result['status'] == 'ready'
    assert result['matrix_room_id'] == TARGET
    assert result['room_ids'] == [OLD, TARGET]
    with repair.factory() as session:
        assert session.get(DirectConversation, 'canonical').matrix_room_id == TARGET


def test_healthy_canonical_never_switches(repair):
    repair.matrix_gateway.states[OLD] = repair.matrix_gateway.states[TARGET]
    result = resolve(repair)
    assert result['status'] == 'ready'
    assert result['matrix_room_id'] == OLD


def test_no_source_reserves_one_fixed_generation_concurrently(repair):
    with repair.factory.begin() as session:
        session.execute(delete(DirectConversationRoom))
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(lambda _: resolve(repair), range(4)))
    assert all(row == results[0] for row in results)
    assert results[0]['status'] == 'create_required'
    assert results[0]['generation'] == 1
    assert results[0]['matrix_room_id'] is None
    assert results[0]['room_alias_localpart'].startswith('chatflow_dm_')
    assert repair.direct_conversation('alice', 'bob')['matrix_room_id'] == OLD


def test_unknown_old_metadata_cannot_create(repair):
    repair.matrix_gateway.details = {'room_id': OLD, 'joined_members': False}
    assert resolve(repair)['status'] == 'unavailable'


def test_target_without_send_power_is_not_selected(repair):
    repair.matrix_gateway.states[TARGET].append({'type': 'm.room.power_levels', 'state_key': '',
        'content': {'events_default': 50, 'users_default': 0}})
    assert resolve(repair)['status'] == 'unavailable'


def test_both_legacy_directory_reads_reconcile(repair):
    assert repair.direct_conversation('alice', 'bob')['matrix_room_id'] == TARGET
    assert repair.direct_conversation_associations('alice', 'bob')['matrix_room_id'] == TARGET


def pending(repair):
    with repair.factory.begin() as session:
        session.execute(delete(DirectConversationRoom))
    result = resolve(repair)
    state = repair.matrix_gateway.states[TARGET]
    state.append({'type': 'com.chatflow.direct_reservation', 'state_key': '',
                  'content': {'reservation_id': result['reservation_id']}})
    repair.matrix_gateway.resolve_room_alias = lambda alias: TARGET
    return result


def publish(repair, result, **changes):
    values = dict(actor='alice', peer='bob', attempt_id=str(uuid4()), generation=result['generation'],
                  reservation_id=result['reservation_id'], matrix_room_id=TARGET)
    values.update(changes)
    return repair.publish_direct_recovery(**values)


def test_generation_publication_replay_preserves_sources_and_revision(repair):
    result = pending(repair)
    published = publish(repair, result)
    assert published == {'matrix_room_id': TARGET, 'generation': 1, 'revision': 1}
    assert publish(repair, result) == published
    assert resolve(repair)['room_ids'] == [OLD, TARGET]


@pytest.mark.parametrize('change', ['healthy', 'invite', 'ban', 'unknown'])
def test_publish_rechecks_old_retirement_after_resolution(repair, change):
    result = pending(repair)
    if change == 'unknown':
        repair.matrix_gateway.details = {}
    else:
        repair.matrix_gateway.states[OLD] = [
            {'type': 'm.room.member', 'state_key': '@alice:example.test',
             'content': {'membership': 'join' if change == 'healthy' else change}},
        ]
    with pytest.raises(AppError):
        publish(repair, result)
    with repair.factory() as session:
        assert session.get(DirectConversation, 'canonical').matrix_room_id == OLD


@pytest.mark.parametrize('change', ['alias', 'marker', 'generation', 'reservation'])
def test_publication_fences_alias_marker_and_generation(repair, change):
    result = pending(repair)
    kwargs = {}
    if change == 'alias':
        repair.matrix_gateway.resolve_room_alias = lambda alias: '!unrelated:test'
    elif change == 'marker':
        repair.matrix_gateway.states[TARGET][-1]['content']['reservation_id'] = 'wrong'
    else:
        kwargs['generation' if change == 'generation' else 'reservation_id'] = 2 if change == 'generation' else str(uuid4())
    with pytest.raises(AppError):
        publish(repair, result, **kwargs)
    assert resolve(repair)['reservation_id'] == result['reservation_id']


def test_join_required_does_not_allocate_generation(repair):
    repair.matrix_gateway.states[OLD] = repair.matrix_gateway.states[TARGET]
    repair.matrix_gateway.states[OLD][1]['content']['membership'] = 'leave'
    result = repair.resolve_direct_conversation('bob', 'alice', str(uuid4()))
    assert result['status'] == 'join_required'
    assert result['matrix_room_id'] == OLD
    assert result['reservation_id'] is None


@pytest.mark.parametrize('power', [True, '50', None, 0.0])
def test_malformed_power_levels_fail_closed(repair, power):
    repair.matrix_gateway.states[TARGET].append({'type': 'm.room.power_levels', 'state_key': '',
        'content': {'events_default': power}})
    assert resolve(repair)['status'] == 'unavailable'


def test_legacy_endpoints_share_probe_cooldown(repair):
    repair.matrix_gateway.states[OLD] = repair.matrix_gateway.states[TARGET]
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(lambda i: repair.direct_conversation('alice', 'bob') if i % 2
                      else repair.direct_conversation_associations('alice', 'bob'), range(4)))
    assert repair.matrix_gateway.reads.count(('state', OLD)) == 1


def test_inactive_account_cannot_resolve_or_change_legacy_mapping(repair):
    from app.modules.identity.models import User
    from app.modules.identity.enums import AccountStatus
    with repair.factory.begin() as session:
        session.get(User, 'bob').status = AccountStatus.DISABLED
    with pytest.raises(AppError) as error:
        resolve(repair)
    assert error.value.status_code == 403
    assert repair.direct_conversation('alice', 'bob')['matrix_room_id'] == OLD


def test_block_unblock_does_not_consume_legacy_creation(service):
    service.block('alice', 'bob', 'block-test')
    service.unblock('alice', 'bob', 'unblock-test')
    assert service.claim_direct_conversation('alice', 'bob', str(uuid4()))['may_create'] is True


def test_initial_creation_reuses_v2_alias_and_unified_publish(repair):
    with repair.factory.begin() as session:
        session.execute(delete(DirectConversationRoom))
        session.execute(delete(DirectConversation))
    first = resolve(repair)
    legacy = repair.claim_direct_conversation_v2('bob', 'alice', str(uuid4()))
    assert first['generation'] == 0
    assert first['reservation_id'] == legacy['reservation_id']
    assert first['room_alias_localpart'] == legacy['room_alias_localpart']
    repair.matrix_gateway.states[TARGET].append({'type': 'com.chatflow.direct_reservation', 'state_key': '',
        'content': {'reservation_id': first['reservation_id']}})
    repair.matrix_gateway.resolve_room_alias = lambda alias: TARGET
    assert publish(repair, first) == {'matrix_room_id': TARGET, 'generation': 0, 'revision': 0}


def test_late_old_publish_cannot_return_stale_destination(repair):
    first = pending(repair)
    publish(repair, first)
    healthy = repair.matrix_gateway.states[TARGET]
    repair.matrix_gateway.states[TARGET] = []
    repair.matrix_gateway.get_room_details = lambda room: {'room_id': room, 'joined_members': 0}
    second = resolve(repair)
    assert second['generation'] == 2
    new = '!new:test'
    repair.matrix_gateway.states[new] = [event for event in healthy if event['type'] != 'com.chatflow.direct_reservation'] + [
        {'type': 'com.chatflow.direct_reservation', 'state_key': '', 'content': {'reservation_id': second['reservation_id']}}]
    repair.matrix_gateway.resolve_room_alias = lambda alias: new
    assert publish(repair, second, matrix_room_id=new)['revision'] == 2
    with pytest.raises(AppError) as conflict:
        publish(repair, first)
    assert conflict.value.code == 'DIRECT_ROOM_GENERATION_CONFLICT'


def test_probe_expired_after_network_never_changes_mapping(repair, monkeypatch):
    from app.modules.friendship import direct_conversation_lifecycle as lifecycle
    now = [0.0]
    monkeypatch.setattr(lifecycle, 'monotonic', lambda: now[0])
    original = repair.matrix_gateway.get_room_state_strict
    def delayed(room):
        result = original(room)
        now[0] += 10
        return result
    repair.matrix_gateway.get_room_state_strict = delayed
    assert resolve(repair)['status'] == 'unavailable'
    with repair.factory() as session:
        assert session.get(DirectConversation, 'canonical').revision == 0


def test_budget_expiring_after_mutation_rolls_back_before_commit(repair, monkeypatch):
    from app.modules.friendship import direct_conversation_lifecycle as lifecycle
    now = [0.0]
    monkeypatch.setattr(lifecycle, 'monotonic', lambda: now[0])
    original = repair._reply
    def delayed_reply(*args, **kwargs):
        result = original(*args, **kwargs)
        now[0] = 5.0
        return result
    monkeypatch.setattr(repair, '_reply', delayed_reply)
    assert resolve(repair)['status'] == 'unavailable'
    with repair.factory() as session:
        row = session.get(DirectConversation, 'canonical')
        assert row.matrix_room_id == OLD and row.revision == 0


def test_legacy_missing_canonical_does_not_consume_creation(repair):
    with repair.factory.begin() as session:
        session.execute(delete(DirectConversation))
    assert repair.direct_conversation('alice', 'bob')['matrix_room_id'] is None
    assert repair.claim_direct_conversation('alice', 'bob', str(uuid4()))['may_create'] is True


def test_candidate_bound_still_uses_first_healthy_source(repair):
    from datetime import datetime, timezone, timedelta
    with repair.factory.begin() as session:
        for i in range(5):
            session.add(DirectConversationRoom(id=str(uuid4()), user_low_id='alice', user_high_id='bob',
                matrix_room_id=f'!later{i}:test', created_at=datetime.now(timezone.utc) + timedelta(days=1)))
    assert resolve(repair)['matrix_room_id'] == TARGET
    assert not any(room.startswith('!later') for _, room in repair.matrix_gateway.reads)


def test_unknown_candidate_does_not_hide_later_healthy_source(repair):
    from datetime import datetime, timezone, timedelta
    with repair.factory.begin() as session:
        session.add(DirectConversationRoom(id=str(uuid4()), user_low_id='alice', user_high_id='bob',
            matrix_room_id='!unknown:test', created_at=datetime.now(timezone.utc) - timedelta(days=1)))
    repair.matrix_gateway.states['!unknown:test'] = None
    assert resolve(repair)['matrix_room_id'] == TARGET


@pytest.mark.parametrize('healthy_index', [4, 5])
def test_bounded_scan_advances_to_later_healthy_source(repair, healthy_index):
    from datetime import datetime, timezone
    healthy = repair.matrix_gateway.states[TARGET]
    rooms = [f'!source{i}:test' for i in range(6)]
    with repair.factory.begin() as session:
        session.execute(delete(DirectConversationRoom))
        for room in rooms:
            session.add(DirectConversationRoom(id=str(uuid4()), user_low_id='alice', user_high_id='bob',
                matrix_room_id=room, created_at=datetime.now(timezone.utc)))
    for index, room in enumerate(rooms):
        repair.matrix_gateway.states[room] = healthy if index == healthy_index else []
    repair.matrix_gateway.get_room_details = lambda room: {'room_id': room, 'joined_members': 0}
    with pytest.raises(AppError):
        repair._resolve('alice', 'bob', str(uuid4()), create=False)
    subsequent = [resolve(repair) for _ in range(2)]
    assert any(result['matrix_room_id'] == rooms[healthy_index] for result in subsequent)


def test_candidate_list_change_resets_scan_progress(repair):
    from datetime import datetime, timezone, timedelta
    healthy = repair.matrix_gateway.states[TARGET]
    with repair.factory.begin() as session:
        session.execute(delete(DirectConversationRoom))
        for index in range(6):
            room = f'!source{index}:test'
            session.add(DirectConversationRoom(id=str(uuid4()), user_low_id='alice', user_high_id='bob',
                matrix_room_id=room, created_at=datetime.now(timezone.utc)))
            repair.matrix_gateway.states[room] = []
    repair.matrix_gateway.get_room_details = lambda room: {'room_id': room, 'joined_members': 0}
    with pytest.raises(AppError):
        repair._resolve('alice', 'bob', str(uuid4()), create=False)
    with repair.factory.begin() as session:
        session.add(DirectConversationRoom(id=str(uuid4()), user_low_id='alice', user_high_id='bob',
            matrix_room_id=TARGET, created_at=datetime.now(timezone.utc) - timedelta(days=1)))
    repair.matrix_gateway.states[TARGET] = healthy
    before = len(repair.matrix_gateway.reads)
    assert resolve(repair)['matrix_room_id'] == TARGET
    assert [room for kind, room in repair.matrix_gateway.reads[before:] if kind == 'state' and room != OLD][0] == TARGET


def test_scan_progress_cache_is_bounded(repair, monkeypatch):
    from app.modules.friendship import direct_conversation_lifecycle as lifecycle
    monkeypatch.setattr(lifecycle, 'SCAN_CACHE_LIMIT', 2)
    monkeypatch.setattr(lifecycle, '_scan_cursors', lifecycle.OrderedDict())
    candidates = [f'!source{i}:test' for i in range(6)]
    for index in range(5):
        assert repair._candidate_window('alice', f'peer{index}', OLD, candidates) == candidates[:4]
    assert len(lifecycle._scan_cursors) == 2
    # Eviction discards progress only, so an evicted pair restarts safely.
    assert repair._candidate_window('alice', 'peer0', OLD, candidates) == candidates[:4]


def partial_old(repair):
    from copy import deepcopy
    repair.matrix_gateway.states[OLD] = deepcopy(repair.matrix_gateway.states[TARGET])
    repair.matrix_gateway.states[OLD][1]['content']['membership'] = 'leave'


def test_departed_requester_can_reuse_healthy_source_but_get_cannot(repair):
    partial_old(repair)
    assert repair.direct_conversation('alice', 'bob')['matrix_room_id'] == OLD
    assert repair.direct_conversation_associations('alice', 'bob')['matrix_room_id'] == OLD
    assert resolve(repair)['matrix_room_id'] == TARGET


def partial_pending(repair):
    partial_old(repair)
    result = pending(repair)
    assert result['status'] == 'create_required'
    return result


def test_partial_generation_shared_and_peer_can_publish(repair):
    result = partial_pending(repair)
    opposite = repair.resolve_direct_conversation('bob', 'alice', str(uuid4()))
    assert opposite['reservation_id'] == result['reservation_id']
    assert publish(repair, result, actor='bob', peer='alice')['matrix_room_id'] == TARGET


@pytest.mark.parametrize('membership', ['join', 'invite', 'ban', None])
def test_partial_generation_reentry_blocks_publication(repair, membership):
    result = partial_pending(repair)
    repair.matrix_gateway.states[OLD][1]['content']['membership'] = membership
    with pytest.raises(AppError):
        publish(repair, result)
    with repair.factory() as session:
        assert session.get(DirectConversation, 'canonical').matrix_room_id == OLD


def test_partial_generation_both_leave_keeps_same_alias(repair):
    result = partial_pending(repair)
    repair.matrix_gateway.states[OLD][2]['content']['membership'] = 'leave'
    again = repair.resolve_direct_conversation('bob', 'alice', str(uuid4()))
    assert again['reservation_id'] == result['reservation_id']
    assert publish(repair, result, actor='bob', peer='alice')['matrix_room_id'] == TARGET


def test_partial_generation_empty_retired_synapse_state_keeps_alias(repair):
    result = partial_pending(repair)
    repair.matrix_gateway.states[OLD] = []
    again = repair.resolve_direct_conversation('bob', 'alice', str(uuid4()))
    assert again['status'] == 'create_required'
    assert again['reservation_id'] == result['reservation_id']
    assert publish(repair, result, actor='bob', peer='alice')['matrix_room_id'] == TARGET


@pytest.mark.parametrize('source_count', [2, 4, 8])
def test_slow_window_heads_do_not_starve_later_healthy_source(repair, monkeypatch, source_count):
    from datetime import datetime, timezone
    from app.modules.friendship import direct_conversation_lifecycle as lifecycle
    now = [0.0]
    monkeypatch.setattr(lifecycle, 'monotonic', lambda: now[0])
    healthy = repair.matrix_gateway.states[TARGET]
    with repair.factory.begin() as session:
        session.execute(delete(DirectConversationRoom))
        for index in range(source_count):
            room = f'!source{index}:test'
            session.add(DirectConversationRoom(id=str(uuid4()), user_low_id='alice', user_high_id='bob',
                matrix_room_id=room, created_at=datetime.now(timezone.utc)))
            repair.matrix_gateway.states[room] = healthy if index == 1 else []
    repair.matrix_gateway.get_room_details = lambda room: {'room_id': room, 'joined_members': 0}
    original = repair.matrix_gateway.get_room_state_strict
    def probe(room):
        if room in {'!source0:test', '!source4:test'}:
            now[0] += 10
        return original(room)
    repair.matrix_gateway.get_room_state_strict = probe
    results = [resolve(repair) for _ in range(8)]
    assert any(row['status'] == 'ready' and row['matrix_room_id'] == '!source1:test' for row in results)


@pytest.mark.parametrize('unknown', [False, True])
def test_five_retired_sources_need_fresh_complete_proof_before_generation(repair, unknown):
    from datetime import datetime, timezone
    from app.modules.friendship.models import DirectRoomGeneration
    with repair.factory.begin() as session:
        session.execute(delete(DirectConversationRoom))
        for index in range(5):
            room = f'!source{index}:test'
            session.add(DirectConversationRoom(id=str(uuid4()), user_low_id='alice', user_high_id='bob',
                matrix_room_id=room, created_at=datetime.now(timezone.utc)))
            repair.matrix_gateway.states[room] = None if unknown and index == 4 else []
    repair.matrix_gateway.get_room_details = lambda room: {'room_id': room, 'joined_members': 0}
    assert repair.direct_conversation('alice', 'bob')['matrix_room_id'] == OLD
    with repair.factory() as session:
        assert session.scalar(select(DirectRoomGeneration)) is None
    result = resolve(repair)
    assert result['status'] == ('unavailable' if unknown else 'create_required')
    with repair.factory() as session:
        assert (session.scalar(select(DirectRoomGeneration)) is None) == unknown


def test_generation_reserve_replay_adds_no_audit_or_outbox(repair):
    from test_retired_direct_room_repair import counts
    result = pending(repair)
    before = counts(repair)
    assert resolve(repair)['reservation_id'] == result['reservation_id']
    assert counts(repair) == before


def test_initial_publish_has_one_publication_outbox(repair):
    from app.core.outbox import OutboxEvent
    test_initial_creation_reuses_v2_alias_and_unified_publish(repair)
    with repair.factory() as session:
        rows = list(session.scalars(select(OutboxEvent).where(OutboxEvent.event_type == 'friend.direct_room_recovered')))
    assert len(rows) == 1


@pytest.mark.asyncio
async def test_resolver_and_publication_api_contract(repair):
    from app.main import create_app
    from app.core.config import Settings
    from app.modules.identity.models import User
    from httpx import ASGITransport, AsyncClient
    from test_friendship_api import bearer, MemoryAvatarStorage
    with repair.factory.begin() as session:
        session.execute(delete(DirectConversationRoom))
        for user in ('alice', 'bob'):
            session.get(User, user).matrix_user_id = f'@{user}:example.test'
    settings = Settings(_env_file=None, environment='test', jwt_secret='x' * 32, matrix_server_name='example.test')
    app = create_app(settings, session_factory=repair.factory, matrix_gateway=repair.matrix_gateway,
                     avatar_storage=MemoryAvatarStorage())
    body = {'peer_user_id': 'bob', 'attempt_id': str(uuid4())}
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        assert (await client.post('/api/v1/direct-conversations/resolve', json=body)).status_code == 401
        headers = bearer(settings, 'alice')
        invalid = await client.post('/api/v1/direct-conversations/resolve', headers=headers, json={**body, 'attempt_id': 'bad'})
        assert invalid.status_code == 422
        response = await client.post('/api/v1/direct-conversations/resolve', headers=headers, json=body)
        assert response.status_code == 200
        result = response.json()
        assert result['status'] == 'create_required' and result['revision'] == 0
        repair.matrix_gateway.states[TARGET].append({'type': 'com.chatflow.direct_reservation', 'state_key': '',
            'content': {'reservation_id': result['reservation_id']}})
        repair.matrix_gateway.resolve_room_alias = lambda alias: TARGET
        response = await client.post('/api/v1/direct-conversations/publish-recovery', headers=headers,
            json={**body, 'generation': result['generation'], 'reservation_id': result['reservation_id'], 'matrix_room_id': TARGET})
        assert response.status_code == 200
        assert response.json() == {'matrix_room_id': TARGET, 'generation': 1, 'revision': 1}
