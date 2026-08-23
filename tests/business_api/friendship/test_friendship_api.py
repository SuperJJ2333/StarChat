from datetime import datetime, timedelta, timezone
import jwt
import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool
from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.main import create_app
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User


class MemoryAvatarStorage:
    def put(self, object_key, content):
        pass

    def get(self, object_key):
        raise KeyError(object_key)

    def delete(self, object_key):
        pass

    def signed_read_url(self, object_key, expires_in):
        assert expires_in == 300
        return f"https://media.example.test/{object_key.rsplit('/', 1)[-1]}?signed=1"

def bearer(settings, user):
    now = datetime.now(timezone.utc)
    token = jwt.encode({'sub': user, 'iss': settings.jwt_issuer, 'iat': int(now.timestamp()), 'exp': int((now + timedelta(minutes=5)).timestamp())}, settings.jwt_secret, algorithm='HS256')
    return {'Authorization': f'Bearer {token}'}

@pytest.fixture
def ctx():
    engine = create_engine('sqlite+pysqlite:///:memory:', connect_args={'check_same_thread': False}, poolclass=StaticPool)
    Base.metadata.create_all(engine); factory = create_session_factory(engine); now = datetime.now(timezone.utc)
    with factory.begin() as session:
        for user_id, name, nickname in [('u1', 'alice', 'Alice'), ('u2', 'bob', 'Bobby')]:
            session.add(User(id=user_id, username=name, username_normalized=name, email=f'{name}@x.test', email_normalized=f'{name}@x.test', password_hash='x', status=AccountStatus.ACTIVE, matrix_user_id=f'@{name}:matrix.example.test', nickname=nickname, signature=f'{nickname} signature', avatar_object_key=f'avatars/{user_id}/avatar.png', profile_updated_at=now, created_at=now, updated_at=now))
    settings = Settings(_env_file=None, environment='test', jwt_secret='x' * 32)
    yield create_app(settings, session_factory=factory, avatar_storage=MemoryAvatarStorage()), settings

@pytest.mark.asyncio
async def test_request_accept_list_block_and_search(ctx):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        request = await client.post('/api/v1/friends/requests', headers={**bearer(settings, 'u1'), 'Idempotency-Key': 'r1'}, json={'target_user_id': 'u2', 'message': '你好'})
        assert request.status_code == 201
        accepted = await client.post(f"/api/v1/friends/requests/{request.json()['id']}/accept", headers={**bearer(settings, 'u2'), 'Idempotency-Key': 'a1'})
        assert accepted.status_code == 200
        friends = await client.get('/api/v1/friends', headers=bearer(settings, 'u1'))
        friend = friends.json()['items'][0]
        assert set(friend) == {'user_id', 'username', 'nickname', 'remark', 'avatar_url', 'matrix_user_id', 'moments_permission', 'tags'}
        assert friend == {'user_id': 'u2', 'username': 'bob', 'nickname': 'Bobby', 'remark': None, 'avatar_url': 'https://media.example.test/avatar.png?signed=1', 'matrix_user_id': '@bob:matrix.example.test', 'moments_permission': 'DEFAULT', 'tags': []}
        blocked = await client.post('/api/v1/blocks', headers={**bearer(settings, 'u1'), 'Idempotency-Key': 'b1'}, json={'user_id': 'u2'})
        assert blocked.status_code == 201
        search = await client.get('/api/v1/users/search?q=bob', headers=bearer(settings, 'u1'))
        assert search.json()['items'] == []

@pytest.mark.asyncio
async def test_friend_requests_and_search_return_business_profile_projection(ctx):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        created = await client.post('/api/v1/friends/requests', headers={**bearer(settings, 'u1'), 'Idempotency-Key': 'projection-request'}, json={'target_user_id': 'u2', 'message': '你好'})
        assert created.status_code == 201
        requests = await client.get('/api/v1/friends/requests', headers=bearer(settings, 'u2'))
        request_item = requests.json()['items'][0]
        assert 'requester_id' not in request_item
        assert request_item == {'id': created.json()['id'], 'username': 'alice', 'nickname': 'Alice', 'avatar_url': 'https://media.example.test/avatar.png?signed=1', 'message': '你好', 'status': 'PENDING', 'requested_at': request_item['requested_at']}; assert request_item['requested_at']
        search = await client.get('/api/v1/users/search?q=alice', headers=bearer(settings, 'u2'))
        assert search.json()['items'] == [{'user_id': 'u1', 'username': 'alice', 'nickname': 'Alice', 'avatar_url': 'https://media.example.test/avatar.png?signed=1', 'matrix_user_id': '@alice:matrix.example.test', 'relationship_state': 'NONE'}]


@pytest.mark.asyncio
async def test_friend_request_rejects_idempotency_key_reuse_for_changed_payload(ctx):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        headers = {**bearer(settings, 'u1'), 'Idempotency-Key': 'same-request-key'}
        first = await client.post('/api/v1/friends/requests', headers=headers, json={'target_user_id': 'u2', 'message': 'one'})
        changed = await client.post('/api/v1/friends/requests', headers=headers, json={'target_user_id': 'u2', 'message': 'two'})

    assert first.status_code == 201
    assert changed.status_code == 409
    assert changed.json()['error']['code'] == 'IDEMPOTENCY_KEY_REUSED'

@pytest.mark.asyncio
async def test_reject_update_privacy_and_delete_friend(ctx):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        request = await client.post('/api/v1/friends/requests', headers={**bearer(settings, 'u1'), 'Idempotency-Key': 'r2'}, json={'target_user_id': 'u2'})
        rejected = await client.post(f"/api/v1/friends/requests/{request.json()['id']}/reject", headers={**bearer(settings, 'u2'), 'Idempotency-Key': 'reject-1'})
        assert rejected.json()['status'] == 'REJECTED'
        request2 = await client.post('/api/v1/friends/requests', headers={**bearer(settings, 'u1'), 'Idempotency-Key': 'r3'}, json={'target_user_id': 'u2'})
        await client.post(f"/api/v1/friends/requests/{request2.json()['id']}/accept", headers={**bearer(settings, 'u2'), 'Idempotency-Key': 'accept-2'})
        updated = await client.patch('/api/v1/friends/u2', headers={**bearer(settings, 'u1'), 'Idempotency-Key': 'profile-1'}, json={'remark': '小波', 'tags': ['同事'], 'moments_permission': 'HIDE_THEIRS'})
        assert updated.json()['remark'] == '小波'
        deleted = await client.delete('/api/v1/friends/u2', headers={**bearer(settings, 'u1'), 'Idempotency-Key': 'delete-1'})
        assert deleted.status_code == 204

@pytest.mark.asyncio
async def test_block_list_unblock_and_contact_tags(ctx):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        blocked = await client.post('/api/v1/blocks', headers={**bearer(settings, 'u1'), 'Idempotency-Key': 'block-list'}, json={'user_id': 'u2'})
        assert blocked.status_code == 201
        assert (await client.get('/api/v1/blocks', headers=bearer(settings, 'u1'))).json()['items'][0]['user_id'] == 'u2'
        assert (await client.delete('/api/v1/blocks/u2', headers={**bearer(settings, 'u1'), 'Idempotency-Key': 'unblock'})).status_code == 204
        created = await client.post('/api/v1/contact-tags', headers={**bearer(settings, 'u1'), 'Idempotency-Key': 'tag-create'}, json={'name': '同事'})
        assert created.status_code == 201
        assert (await client.get('/api/v1/contact-tags', headers=bearer(settings, 'u1'))).json()['items'][0]['name'] == '同事'
        assert (await client.delete(f"/api/v1/contact-tags/{created.json()['id']}", headers={**bearer(settings, 'u1'), 'Idempotency-Key': 'tag-delete'})).status_code == 204

@pytest.mark.asyncio
async def test_contact_tag_can_be_renamed_by_its_owner(ctx):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        created = await client.post('/api/v1/contact-tags', headers={**bearer(settings, 'u1'), 'Idempotency-Key': 'tag-create-rename'}, json={'name': '同事'})
        assert created.status_code == 201
        renamed = await client.patch(f"/api/v1/contact-tags/{created.json()['id']}", headers={**bearer(settings, 'u1'), 'Idempotency-Key': 'tag-rename'}, json={'name': '项目组'})
        assert renamed.status_code == 200
        assert renamed.json()['name'] == '项目组'
        assert (await client.get('/api/v1/contact-tags', headers=bearer(settings, 'u1'))).json()['items'][0]['name'] == '项目组'

@pytest.mark.asyncio
async def test_friend_request_prevents_pending_and_existing_friend_duplicates(ctx):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        first = await client.post('/api/v1/friends/requests', headers={**bearer(settings, 'u1'), 'Idempotency-Key': 'pending-1'}, json={'target_user_id': 'u2', 'message': 'first'})
        duplicate = await client.post('/api/v1/friends/requests', headers={**bearer(settings, 'u1'), 'Idempotency-Key': 'pending-2'}, json={'target_user_id': 'u2', 'message': 'second'})
        assert duplicate.status_code == 409
        assert duplicate.json()['error']['code'] == 'FRIEND_REQUEST_DUPLICATE'
        assert duplicate.json()['error']['message'] == '不能重复发送好友请求'
        accepted = await client.post(f"/api/v1/friends/requests/{first.json()['id']}/accept", headers={**bearer(settings, 'u2'), 'Idempotency-Key': 'pending-accept'})
        assert accepted.status_code == 200
        friend_duplicate = await client.post('/api/v1/friends/requests', headers={**bearer(settings, 'u2'), 'Idempotency-Key': 'friend-duplicate'}, json={'target_user_id': 'u1'})
        assert friend_duplicate.status_code == 409
        assert friend_duplicate.json()['error']['code'] == 'FRIEND_REQUEST_DUPLICATE'


@pytest.mark.asyncio
async def test_rejected_request_is_reused_with_latest_request_time(ctx):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        initial = await client.post('/api/v1/friends/requests', headers={**bearer(settings, 'u1'), 'Idempotency-Key': 'reuse-first'}, json={'target_user_id': 'u2', 'message': 'old'})
        rejected = await client.post(f"/api/v1/friends/requests/{initial.json()['id']}/reject", headers={**bearer(settings, 'u2'), 'Idempotency-Key': 'reuse-reject'})
        assert rejected.status_code == 200
        retried = await client.post('/api/v1/friends/requests', headers={**bearer(settings, 'u1'), 'Idempotency-Key': 'reuse-second'}, json={'target_user_id': 'u2', 'message': 'new'})
        assert retried.status_code == 201
        assert retried.json()['id'] == initial.json()['id']
        requests = await client.get('/api/v1/friends/requests', headers=bearer(settings, 'u2'))
        item = requests.json()['items'][0]
        assert item['id'] == initial.json()['id']
        assert item['message'] == 'new'
        assert item['status'] == 'PENDING'
        assert item['requested_at']

@pytest.mark.asyncio
async def test_search_returns_authoritative_relationship_state(ctx):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        initial = await client.get('/api/v1/users/search?q=bob', headers=bearer(settings, 'u1'))
        assert initial.json()['items'][0]['relationship_state'] == 'NONE'
        pending = await client.post('/api/v1/friends/requests', headers={**bearer(settings, 'u1'), 'Idempotency-Key': 'relationship-pending'}, json={'target_user_id': 'u2'})
        assert pending.status_code == 201
        outgoing = await client.get('/api/v1/users/search?q=bob', headers=bearer(settings, 'u1'))
        assert outgoing.json()['items'][0]['relationship_state'] == 'OUTGOING_PENDING'
