from types import SimpleNamespace
from uuid import uuid4

import pytest

from app.core.errors import AppError
from test_direct_room_coordination import service  # noqa: F401
from test_friend_refactor import friend_components  # noqa: F401


class Matrix:
    def __init__(self):
        self.states = {}
        self.aliases = {}

    def get_room_state(self, room):
        return self.states.get(room, [])

    def resolve_room_alias(self, alias):
        return self.aliases.get(alias)


@pytest.fixture
def recovery(service):
    service.matrix_gateway = Matrix()
    service.matrix_server_name = 'example.test'
    service.profile_reader.read_public_profiles = lambda ids: {
        user: SimpleNamespace(matrix_user_id=f'@{user}:example.test') for user in ids
    }
    return service


def room(service, claim, room_id='!safe:example.test', extra=None):
    state = [
        {'type': 'm.room.encryption', 'state_key': '', 'content': {'algorithm': 'm.megolm.v1.aes-sha2'}},
        *[{'type': 'm.room.member', 'state_key': f'@{u}:example.test', 'content': {'membership': m}}
          for u, m in [('alice', 'join'), ('bob', 'invite')]],
        {'type': 'com.chatflow.direct_reservation', 'state_key': '', 'content': {'reservation_id': claim['reservation_id']}},
    ]
    if extra:
        state.append(extra)
    service.matrix_gateway.states[room_id] = state
    service.matrix_gateway.aliases[f"#{claim['room_alias_localpart']}:example.test"] = room_id
    return room_id


def test_lost_claim_replays_same_safe_alias(recovery):
    first = recovery.claim_direct_conversation_v2('alice', 'bob', str(uuid4()))
    second = recovery.claim_direct_conversation_v2('bob', 'alice', str(uuid4()))
    assert first == second
    assert first['may_create']


@pytest.mark.parametrize('operation', ['register', 'publish'])
def test_legacy_first_publication_requires_authoritative_evidence(recovery, operation):
    attempt = str(uuid4())
    if operation == 'publish':
        recovery.claim_direct_conversation('alice', 'bob', attempt)
    with pytest.raises(AppError) as rejected:
        if operation == 'register':
            recovery.register_direct_conversation('alice', 'bob', '!unverified:example.test', attempt)
        else:
            recovery.publish_direct_conversation('alice', 'bob', attempt, '!unverified:example.test')
    assert rejected.value.code == 'DIRECT_ROOM_INVALID_EVIDENCE'
    assert recovery.direct_conversation('alice', 'bob') == {'matrix_room_id': None}


@pytest.mark.parametrize('operation', ['register', 'publish'])
def test_valid_late_legacy_room_is_retained_for_non_v2_canonical(recovery, operation):
    from app.modules.friendship.models import DirectConversation
    from datetime import datetime, timezone
    with recovery.factory.begin() as session:
        session.add(DirectConversation(id=str(uuid4()), user_low_id='alice', user_high_id='bob',
            matrix_room_id='!original:example.test', created_at=datetime.now(timezone.utc)))
    candidate = room(recovery, {'reservation_id': 'old', 'room_alias_localpart': 'unused'}, '!late:example.test')
    if operation == 'register':
        result = recovery.register_direct_conversation('alice', 'bob', candidate, str(uuid4()))
    else:
        result = recovery.publish_direct_conversation('bob', 'alice', str(uuid4()), candidate)
    assert result['matrix_room_id'] == '!original:example.test'
    assert candidate in recovery.direct_conversation_associations('bob', 'alice')['room_ids']


@pytest.mark.parametrize('operation', ['register', 'publish'])
def test_invalid_late_legacy_room_does_not_replace_or_associate(recovery, operation):
    canonical = room(recovery, {'reservation_id': 'old', 'room_alias_localpart': 'unused'})
    recovery.register_direct_conversation('alice', 'bob', canonical, str(uuid4()))
    with pytest.raises(AppError):
        if operation == 'register':
            recovery.register_direct_conversation('alice', 'bob', '!forged:example.test', str(uuid4()))
        else:
            recovery.publish_direct_conversation('bob', 'alice', str(uuid4()), '!forged:example.test')
    assert recovery.direct_conversation_associations('alice', 'bob') == {'matrix_room_id': canonical, 'room_ids': [canonical]}
    recovery.matrix_gateway = None
    # Existing canonical reads/replays do not depend on fresh Matrix availability.
    assert recovery.publish_direct_conversation('bob', 'alice', str(uuid4()), canonical) == {'matrix_room_id': canonical}


def test_lost_create_and_publish_response_recovered_from_evidence(recovery):
    attempt = str(uuid4())
    claim = recovery.claim_direct_conversation_v2('alice', 'bob', attempt)
    candidate = room(recovery, claim)
    for actor, peer in [('alice', 'bob'), ('bob', 'alice')]:
        assert recovery.recover_direct_conversation(actor, peer, attempt, candidate) == {'matrix_room_id': candidate}
    assert not recovery.claim_direct_conversation_v2('alice', 'bob', attempt)['may_create']


def test_legacy_upgrade_fences_late_creator_but_retains_verified_history(recovery):
    old = str(uuid4())
    recovery.claim_direct_conversation('alice', 'bob', old)
    claim = recovery.claim_direct_conversation_v2('bob', 'alice', str(uuid4()))
    assert claim['may_create']
    with pytest.raises(AppError):
        recovery.publish_direct_conversation('alice', 'bob', old, '!late:example.test')
    canonical = room(recovery, claim)
    recovery.recover_direct_conversation('bob', 'alice', str(uuid4()), canonical)
    room(recovery, claim, '!late:example.test')
    assert recovery.publish_direct_conversation('alice', 'bob', old, '!late:example.test') == {'matrix_room_id': canonical}
    assert recovery.direct_conversation_associations('bob', 'alice') == {
        'matrix_room_id': canonical, 'room_ids': ['!late:example.test', canonical]}


def test_unverified_or_wrong_alias_room_never_published(recovery):
    attempt = str(uuid4())
    claim = recovery.claim_direct_conversation_v2('alice', 'bob', attempt)
    candidate = room(recovery, claim, extra={'type': 'm.room.member', 'state_key': '@eve:example.test', 'content': {'membership': 'join'}})
    with pytest.raises(AppError):
        recovery.recover_direct_conversation('alice', 'bob', attempt, candidate)
    room(recovery, claim)
    recovery.matrix_gateway.aliases.clear()
    with pytest.raises(AppError):
        recovery.recover_direct_conversation('alice', 'bob', attempt, candidate)
    assert recovery.direct_conversation('alice', 'bob')['matrix_room_id'] is None


def test_concurrent_upgrades_share_one_identity(recovery):
    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(max_workers=8) as pool:
        claims = list(pool.map(lambda _: recovery.claim_direct_conversation_v2('alice', 'bob', str(uuid4())), range(8)))
    assert len({c['reservation_id'] for c in claims}) == 1
    assert len({c['room_alias_localpart'] for c in claims}) == 1


def test_concurrent_recovery_publishes_once_and_audits_once(recovery):
    from concurrent.futures import ThreadPoolExecutor
    from sqlalchemy import select
    from app.modules.audit.models import AuditEvent
    claim = recovery.claim_direct_conversation_v2('alice', 'bob', str(uuid4()))
    candidate = room(recovery, claim)
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda _: recovery.recover_direct_conversation('alice', 'bob', str(uuid4()), candidate), range(8)))
    assert all(r == {'matrix_room_id': candidate} for r in results)
    with recovery.factory() as session:
        assert len(list(session.scalars(select(AuditEvent).where(AuditEvent.action == 'friend.direct_room_recovered')))) == 1


@pytest.mark.parametrize('change', ['plaintext', 'missing_peer', 'wrong_marker'])
def test_metadata_mismatch_never_creates_association(recovery, change):
    claim = recovery.claim_direct_conversation_v2('alice', 'bob', str(uuid4()))
    candidate = room(recovery, claim)
    state = recovery.matrix_gateway.states[candidate]
    if change == 'plaintext':
        state[0]['content']['algorithm'] = 'none'
    elif change == 'missing_peer':
        state[2]['content']['membership'] = 'leave'
    else:
        state[3]['content']['reservation_id'] = str(uuid4())
    with pytest.raises(AppError):
        recovery.recover_direct_conversation('alice', 'bob', str(uuid4()), candidate)
    assert recovery.direct_conversation_associations('alice', 'bob')['room_ids'] == []


def test_history_association_never_changes_canonical(recovery):
    room(recovery, {'reservation_id': 'old', 'room_alias_localpart': 'unused'}, '!original:example.test')
    recovery.register_direct_conversation('alice', 'bob', '!original:example.test', 'old')
    claim = recovery.claim_direct_conversation_v2('alice', 'bob', str(uuid4()))
    candidate = room(recovery, claim, '!history:example.test')
    result = recovery.associate_direct_conversation('alice', 'bob', candidate)
    assert result == {'matrix_room_id': '!original:example.test', 'room_ids': [candidate, '!original:example.test']}
    assert recovery.direct_conversation_associations('bob', 'alice') == result


def test_legacy_lost_create_recovers_existing_room_without_alias(recovery):
    recovery.claim_direct_conversation('alice', 'bob', str(uuid4()))
    candidate = room(recovery, {'reservation_id': 'old', 'room_alias_localpart': 'unused'})
    recovery.matrix_gateway.aliases.clear()
    assert recovery.recover_direct_conversation('bob', 'alice', str(uuid4()), candidate) == {'matrix_room_id': candidate}


def test_matrix_failure_keeps_reservation_replayable(recovery):
    claim = recovery.claim_direct_conversation_v2('alice', 'bob', str(uuid4()))
    candidate = room(recovery, claim)
    def unavailable(_):
        raise AppError(code='DIRECT_ROOM_EVIDENCE_UNAVAILABLE', message='unavailable', status_code=503)
    recovery.matrix_gateway.resolve_room_alias = unavailable
    with pytest.raises(AppError):
        recovery.recover_direct_conversation('alice', 'bob', str(uuid4()), candidate)
    assert recovery.claim_direct_conversation_v2('alice', 'bob', str(uuid4())) == claim


def test_directory_gateway_encodes_alias_and_fails_closed():
    import httpx
    from app.integrations.matrix_admin import SynapseMatrixAdminGateway
    calls = []
    def handler(request):
        calls.append(request)
        return httpx.Response(200, json={'room_id': '!existing:example.test'})
    gateway = SynapseMatrixAdminGateway(homeserver_url='https://matrix.example.test',
        server_name='example.test', admin_access_token='test-only', client=httpx.Client(transport=httpx.MockTransport(handler)))
    assert gateway.resolve_room_alias('#chatflow_dm_opaque:example.test') == '!existing:example.test'
    assert calls[0].url.host == 'matrix.example.test'
    assert '%23chatflow_dm_opaque%3Aexample.test' in calls[0].url.raw_path.decode()


@pytest.mark.asyncio
async def test_recovery_api_requires_authentication_and_valid_attempt():
    from httpx import ASGITransport, AsyncClient
    from test_friend_refactor import _settings
    from app.main import create_app
    app = create_app(_settings())
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        for path in ['claim-v2', 'recover', 'associations']:
            result = await client.post('/api/v1/direct-conversations/' + path, json={
                'peer_user_id': 'bob', 'attempt_id': str(uuid4()), 'matrix_room_id': '!room:example.test'})
            assert result.status_code == 401
        assert (await client.get('/api/v1/direct-conversations/associations?peer_user_id=bob')).status_code == 401


@pytest.mark.asyncio
async def test_recovery_api_wires_gateway_and_shared_associations(friend_components):
    from httpx import ASGITransport, AsyncClient
    from test_friend_refactor import _settings, _token
    from app.main import create_app
    from app.modules.identity.models import User
    _, factory = friend_components
    with factory.begin() as session:
        for user in ('alice', 'bob'):
            session.get(User, user).matrix_user_id = f'@{user}:example.test'
    gateway = Matrix()
    settings = _settings().model_copy(update={'matrix_server_name': 'example.test'})
    app = create_app(settings, session_factory=factory, matrix_gateway=gateway)
    alice = {'Authorization': f'Bearer {_token(factory, "alice")}'}
    bob = {'Authorization': f'Bearer {_token(factory, "bob")}'}
    body = {'peer_user_id': 'bob', 'attempt_id': str(uuid4())}
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        invalid = await client.post('/api/v1/direct-conversations/claim-v2', headers=alice, json={**body, 'attempt_id': 'invalid'})
        assert invalid.status_code == 422
        response = await client.post('/api/v1/direct-conversations/claim-v2', headers=alice, json=body)
        assert response.status_code == 200
        claim = response.json()
        candidate = room(SimpleNamespace(matrix_gateway=gateway), claim)
        recovered = await client.post('/api/v1/direct-conversations/recover', headers=alice, json={**body, 'matrix_room_id': candidate})
        assert recovered.status_code == 200
        assert recovered.json() == {'matrix_room_id': candidate}
        associated = await client.get('/api/v1/direct-conversations/associations?peer_user_id=alice', headers=bob)
        assert associated.json() == {'matrix_room_id': candidate, 'room_ids': [candidate]}
