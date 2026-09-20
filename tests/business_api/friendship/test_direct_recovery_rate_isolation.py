"""Background history registration must not starve foreground send recovery."""

from collections import Counter
from types import SimpleNamespace
from uuid import uuid4

import pytest
from httpx import ASGITransport, AsyncClient
import pytest_asyncio

from app.core.errors import AppError
from app.main import create_app
from test_direct_room_recovery import Matrix, room
from test_friend_refactor import _settings, _token, friend_components  # noqa: F401


class RecoveryMatrix(Matrix):
    def get_room_state_strict(self, room_id):
        return self.get_room_state(room_id)


class WindowLimiter:
    """Deterministic single-window limiter; no wall-clock rollover during a test."""

    def __init__(self):
        self.counts = Counter()

    def hit(self, key, *, limit, window_seconds):
        assert (limit, window_seconds) == (60, 60)
        self.counts[key] += 1
        if self.counts[key] > limit:
            raise AppError(code='RATE_LIMITED', message='Too many requests', status_code=429)


@pytest_asyncio.fixture
async def recovery_api(friend_components):
    _, factory = friend_components
    gateway = RecoveryMatrix()
    limiter = WindowLimiter()
    settings = _settings().model_copy(update={'matrix_server_name': 'example.test'})
    app = create_app(settings, session_factory=factory, matrix_gateway=gateway, rate_limiter=limiter)
    headers = {user: {'Authorization': f'Bearer {_token(factory, user)}'} for user in ('alice', 'bob')}
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        accepted = await client.post('/api/v1/friends/requests/req-1/accept', headers={**headers['alice'], 'Idempotency-Key': str(uuid4())})
        assert accepted.status_code == 200
        body = {'peer_user_id': 'bob', 'attempt_id': str(uuid4())}
        claim = await client.post('/api/v1/direct-conversations/claim-v2', headers=headers['alice'], json=body)
        assert claim.status_code == 200
        candidate = room(SimpleNamespace(matrix_gateway=gateway), claim.json())
        publish = await client.post('/api/v1/direct-conversations/recover', headers=headers['alice'],
                              json={**body, 'matrix_room_id': candidate})
        assert publish.status_code == 200
        limiter.counts.clear()
        yield client, headers, candidate, claim.json()


async def post(client, headers, candidate, path, actor='alice', claim=None):
    body = {'peer_user_id': 'bob' if actor == 'alice' else 'alice'}
    if path != 'associations':
        body['attempt_id'] = str(uuid4())
    if path in ('associations', 'recover', 'publish-recovery'):
        body['matrix_room_id'] = candidate
    if path == 'publish-recovery':
        body.update(generation=0, reservation_id=claim['reservation_id'])
    return await client.post('/api/v1/direct-conversations/' + path, headers=headers[actor], json=body)


@pytest.mark.asyncio
@pytest.mark.parametrize('saturated,available', [('associations', 'resolve'), ('resolve', 'associations')])
async def test_background_and_foreground_have_independent_bounded_windows(recovery_api, saturated, available):
    client, headers, candidate, claim = recovery_api
    for _ in range(60):
        assert (await post(client, headers, candidate, saturated)).status_code == 200
    rejected = await post(client, headers, candidate, saturated)
    assert rejected.status_code == 429
    assert rejected.json()['error']['code'] == 'RATE_LIMITED'
    assert (await post(client, headers, candidate, available)).status_code == 200
    # One user's budget exhaustion must not prevent the peer's own recovery.
    assert (await post(client, headers, candidate, saturated, actor='bob')).status_code == 200
    if saturated == 'resolve':
        for path in ('claim-v2', 'recover', 'publish-recovery'):
            assert (await post(client, headers, candidate, path, claim=claim)).status_code == 429


@pytest.mark.asyncio
async def test_isolated_association_route_still_rejects_unverified_membership(recovery_api):
    client, headers, candidate, _ = recovery_api
    rejected = await post(client, headers, '!unverified:example.test', 'associations')
    assert rejected.status_code == 409
    directory = await client.get('/api/v1/direct-conversations/associations?peer_user_id=bob', headers=headers['alice'])
    assert directory.json()['room_ids'] == [candidate]
