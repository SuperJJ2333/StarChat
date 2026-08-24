from datetime import datetime, timedelta, timezone
import jwt, pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool
from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.main import create_app
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User
from app.modules.friendship.models import ContactProfile, ContactTag, Friendship


class MomentAvatarStorage:
    def signed_read_url(self, object_key, expires_in):
        return f"https://media.example.test/{object_key}?signed=1"

def auth(settings, user):
    now = datetime.now(timezone.utc)
    token = jwt.encode({'sub': user, 'iss': settings.jwt_issuer, 'iat': int(now.timestamp()), 'exp': int((now + timedelta(minutes=5)).timestamp())}, settings.jwt_secret, algorithm='HS256')
    return {'Authorization': f'Bearer {token}'}

@pytest.fixture
def ctx():
    engine = create_engine('sqlite+pysqlite:///:memory:', connect_args={'check_same_thread': False}, poolclass=StaticPool)
    Base.metadata.create_all(engine); factory = create_session_factory(engine); now = datetime.now(timezone.utc)
    with factory.begin() as session:
        for user_id, name in [('u1', 'alice'), ('u2', 'bob'), ('u3', 'carol')]:
            session.add(User(id=user_id, username=name, username_normalized=name, email=f'{name}@x', email_normalized=f'{name}@x', password_hash='x', status=AccountStatus.ACTIVE, created_at=now, updated_at=now))
        session.add(Friendship(id='fixture-f12', user_low_id='u1', user_high_id='u2', created_at=now))
    settings = Settings(_env_file=None, environment='test', jwt_secret='x' * 32)
    yield create_app(settings, session_factory=factory), settings

@pytest.mark.asyncio
async def test_public_moment_publish_read_like_comment_search(ctx):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        created = await client.post('/api/v1/moments', headers={**auth(settings, 'u1'), 'Idempotency-Key': 'm1'}, json={'text': '香港风景 #旅行', 'visibility': 'PUBLIC', 'image_urls': []})
        assert created.status_code == 201; moment_id = created.json()['id']
        feed = await client.get('/api/v1/moments/feed?mode=latest', headers=auth(settings, 'u2'))
        assert feed.json()['items'][0]['id'] == moment_id
        assert feed.json()['items'][0]['author'] == {
            'user_id': 'u1',
            'username': 'alice',
            'nickname': 'alice',
            'remark': None,
            'display_name': 'alice',
            'avatar_url': None,
        }
        assert feed.json()['items'][0]['viewer_has_liked'] is False
        liked = await client.post(f'/api/v1/moments/{moment_id}/likes', headers={**auth(settings, 'u2'), 'Idempotency-Key': 'l1'})
        assert liked.status_code == 201
        liked_detail = await client.get(f'/api/v1/moments/{moment_id}', headers=auth(settings, 'u2'))
        assert liked_detail.json()['viewer_has_liked'] is True
        assert liked_detail.json()['like_users'][0]['nickname'] == 'bob'
        comment = await client.post(f'/api/v1/moments/{moment_id}/comments', headers={**auth(settings, 'u2'), 'Idempotency-Key': 'c1'}, json={'text': '真漂亮'})
        assert comment.status_code == 201
        search = await client.get('/api/v1/moments/search?q=香港', headers=auth(settings, 'u2'))
        assert search.json()['items'][0]['id'] == moment_id
        preferences = await client.put('/api/v1/moments/preferences', headers=auth(settings, 'u2'), json={'history_range': 'THREE_DAYS', 'personalized_recommendations': False})
        assert preferences.json()['personalized_recommendations'] is False
        report = await client.post(f'/api/v1/moments/{moment_id}/reports', headers={**auth(settings, 'u2'), 'Idempotency-Key': 'report-1'}, json={'reason_code': 'SPAM'})
        assert report.status_code == 201

        latest = await client.get('/api/v1/moments/feed?mode=latest', headers=auth(settings, 'u2'))
        recommended = await client.get('/api/v1/moments/feed?mode=recommended', headers=auth(settings, 'u2'))
        assert latest.json()['mode'] == 'latest' and recommended.json()['mode'] == 'recommended'


@pytest.mark.asyncio
async def test_identity_projection_keeps_sources_and_uses_viewer_remark(ctx):
    app, settings = ctx
    factory = app.state.session_factory
    with factory.begin() as session:
        alice = session.get(User, 'u1')
        alice.username = 'alice_id'
        alice.username_normalized = 'alice_id'
        alice.nickname = 'Alice'
        alice.avatar_object_key = 'avatars/u1/avatar.png'
        bob = session.get(User, 'u2')
        bob.nickname = 'Bob'
        session.add_all([
            ContactProfile(
                id='cp-u2-u1', owner_id='u2', contact_id='u1',
                remark='项目小爱', tags='', moments_permission='DEFAULT',
            ),
            ContactProfile(
                id='cp-u1-u2', owner_id='u1', contact_id='u2',
                remark='项目小波', tags='', moments_permission='DEFAULT',
            ),
        ])
    projected_app = create_app(
        settings,
        session_factory=factory,
        avatar_storage=MomentAvatarStorage(),
    )
    async with AsyncClient(
        transport=ASGITransport(app=projected_app), base_url='http://test'
    ) as client:
        created = await client.post(
            '/api/v1/moments',
            headers={**auth(settings, 'u1'), 'Idempotency-Key': 'identity-moment'},
            json={'text': '身份投影', 'visibility': 'PUBLIC'},
        )
        moment_id = created.json()['id']
        feed = await client.get(
            '/api/v1/moments/feed?mode=latest', headers=auth(settings, 'u2')
        )
        assert feed.json()['items'][0]['author'] == {
            'user_id': 'u1',
            'username': 'alice_id',
            'nickname': 'Alice',
            'remark': '项目小爱',
            'display_name': '项目小爱',
            'avatar_url': (
                'https://media.example.test/avatars/u1/avatar.png?signed=1'
            ),
        }
        await client.post(
            f'/api/v1/moments/{moment_id}/likes',
            headers={**auth(settings, 'u2'), 'Idempotency-Key': 'identity-like'},
        )
        comment = await client.post(
            f'/api/v1/moments/{moment_id}/comments',
            headers={**auth(settings, 'u2'), 'Idempotency-Key': 'identity-comment'},
            json={'text': '评论身份'},
        )
        assert comment.json()['author']['remark'] is None
        assert comment.json()['author']['display_name'] == 'Bob'
        detail = await client.get(
            f'/api/v1/moments/{moment_id}', headers=auth(settings, 'u1')
        )
        assert detail.json()['like_users'][0]['display_name'] == '项目小波'
        assert detail.json()['comments'][0]['author']['display_name'] == '项目小波'
        refreshed_feed = await client.get(
            '/api/v1/moments/feed?mode=latest', headers=auth(settings, 'u1')
        )
        assert refreshed_feed.json()['items'][0]['comments'][0]['text'] == '评论身份'
        assert (
            refreshed_feed.json()['items'][0]['comments'][0]['author'][
                'display_name'
            ]
            == '项目小波'
        )
        notifications = await client.get(
            '/api/v1/moments/notifications', headers=auth(settings, 'u1')
        )
        assert notifications.json()['items'][0]['actor']['display_name'] == '项目小波'

@pytest.mark.asyncio
async def test_detail_reply_unlike_and_author_moderated_delete(ctx):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        created = await client.post('/api/v1/moments', headers={**auth(settings, 'u1'), 'Idempotency-Key': 'm2'}, json={'text': '可管理动态', 'visibility': 'PUBLIC'})
        moment_id = created.json()['id']
        liked = await client.post(f'/api/v1/moments/{moment_id}/likes', headers={**auth(settings, 'u2'), 'Idempotency-Key': 'like-2'})
        assert liked.status_code == 201
        assert (await client.delete(f'/api/v1/moments/{moment_id}/likes', headers={**auth(settings, 'u2'), 'Idempotency-Key': 'unlike-2'})).status_code == 204
        parent = await client.post(f'/api/v1/moments/{moment_id}/comments', headers={**auth(settings, 'u2'), 'Idempotency-Key': 'comment-2'}, json={'text': '评论'})
        reply = await client.post(f'/api/v1/moments/{moment_id}/comments', headers={**auth(settings, 'u1'), 'Idempotency-Key': 'reply-2'}, json={'text': '回复', 'parent_id': parent.json()['id']})
        assert reply.json()['parent_id'] == parent.json()['id']
        detail = await client.get(f'/api/v1/moments/{moment_id}', headers=auth(settings, 'u2'))
        assert detail.status_code == 200 and len(detail.json()['comments']) == 2
        assert detail.json()['comments'][0]['author']['nickname'] == 'bob'
        assert detail.json()['comments'][1]['parent_author']['nickname'] == 'bob'
        assert (await client.delete(f"/api/v1/moments/{moment_id}/comments/{parent.json()['id']}", headers={**auth(settings, 'u1'), 'Idempotency-Key': 'delete-comment-2'})).status_code == 204
        assert (await client.delete(f'/api/v1/moments/{moment_id}', headers={**auth(settings, 'u2'), 'Idempotency-Key': 'bad-delete'})).status_code == 403
        assert (await client.delete(f'/api/v1/moments/{moment_id}', headers={**auth(settings, 'u1'), 'Idempotency-Key': 'delete-moment-2'})).status_code == 204
        assert (await client.get(f'/api/v1/moments/{moment_id}', headers=auth(settings, 'u2'))).status_code == 404


@pytest.mark.asyncio
async def test_visibility_is_friend_only_and_freezes_tag_audience(ctx):
    app, settings = ctx
    # Build a friendship and a tag containing u2 before publishing.
    factory = app.state.session_factory
    with factory.begin() as session:
        session.add(ContactProfile(id='cp12', owner_id='u1', contact_id='u2', remark=None, tags='家人', moments_permission='DEFAULT'))
        session.add(ContactTag(id='tag-family', owner_id='u1', name='家人', created_at=datetime.now(timezone.utc)))
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        public = await client.post('/api/v1/moments', headers={**auth(settings, 'u1'), 'Idempotency-Key': 'friend-only'}, json={'text': '只给好友', 'visibility': 'PUBLIC'})
        assert (await client.get(f"/api/v1/moments/{public.json()['id']}", headers=auth(settings, 'u2'))).status_code == 200
        assert (await client.get(f"/api/v1/moments/{public.json()['id']}", headers=auth(settings, 'u3'))).status_code == 404
        included = await client.post('/api/v1/moments', headers={**auth(settings, 'u1'), 'Idempotency-Key': 'tag-frozen'}, json={'text': '家人可见', 'visibility': 'INCLUDE', 'include_tag_ids': ['tag-family']})
        assert included.status_code == 201
        assert included.json()['include_user_ids'] == ['u2']
        with factory.begin() as session:
            session.get(ContactProfile, 'cp12').tags = ''
        assert (await client.get(f"/api/v1/moments/{included.json()['id']}", headers=auth(settings, 'u2'))).status_code == 200
        invalid = await client.post('/api/v1/moments', headers={**auth(settings, 'u1'), 'Idempotency-Key': 'bad-audience'}, json={'text': 'bad', 'visibility': 'INCLUDE', 'include_user_ids': ['u3']})
        assert invalid.status_code == 422


@pytest.mark.asyncio
async def test_feed_cursor_is_stable_and_has_no_duplicates(ctx):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        for index in range(3):
            response = await client.post('/api/v1/moments', headers={**auth(settings, 'u1'), 'Idempotency-Key': f'page-{index}'}, json={'text': f'动态 {index}', 'visibility': 'PUBLIC'})
            assert response.status_code == 201
        first = await client.get('/api/v1/moments/feed?mode=latest&limit=2', headers=auth(settings, 'u2'))
        assert len(first.json()['items']) == 2
        assert first.json()['next_cursor']
        second = await client.get(f"/api/v1/moments/feed?mode=latest&limit=2&cursor={first.json()['next_cursor']}", headers=auth(settings, 'u2'))
        assert len(second.json()['items']) == 1
        assert not ({item['id'] for item in first.json()['items']} & {item['id'] for item in second.json()['items']})


@pytest.mark.asyncio
async def test_interaction_notifications_are_private_and_mark_read(ctx):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        created = await client.post('/api/v1/moments', headers={**auth(settings, 'u1'), 'Idempotency-Key': 'notify-moment'}, json={'text': '通知', 'visibility': 'PUBLIC'})
        moment_id = created.json()['id']
        assert (await client.post(f'/api/v1/moments/{moment_id}/likes', headers={**auth(settings, 'u2'), 'Idempotency-Key': 'notify-like'})).status_code == 201
        listed = await client.get('/api/v1/moments/notifications', headers=auth(settings, 'u1'))
        assert listed.json()['items'][0]['kind'] == 'LIKE'
        assert (await client.get('/api/v1/moments/notifications/unread-count', headers=auth(settings, 'u1'))).json()['count'] == 1
        assert (await client.post('/api/v1/moments/notifications/read', headers=auth(settings, 'u1'), json=[listed.json()['items'][0]['id']])).status_code == 204
        assert (await client.get('/api/v1/moments/notifications/unread-count', headers=auth(settings, 'u1'))).json()['count'] == 0
        assert (await client.get('/api/v1/moments/notifications', headers=auth(settings, 'u2'))).json()['items'] == []


@pytest.mark.asyncio
async def test_draft_is_private_and_can_be_deleted(ctx):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        saved = await client.put('/api/v1/moments/draft', headers=auth(settings, 'u1'), json={'payload': {'text': '未发表', 'visibility': 'SELF', 'image_urls': ['cached://1']}})
        assert saved.status_code == 200 and saved.json()['text'] == '未发表'
        assert (await client.get('/api/v1/moments/draft', headers=auth(settings, 'u2'))).status_code == 404
        assert (await client.get('/api/v1/moments/draft', headers=auth(settings, 'u1'))).json()['image_urls'] == ['cached://1']
        assert (await client.delete('/api/v1/moments/draft', headers=auth(settings, 'u1'))).status_code == 204
        assert (await client.get('/api/v1/moments/draft', headers=auth(settings, 'u1'))).status_code == 404
