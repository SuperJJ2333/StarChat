import json
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
    def put(self, object_key, content):
        pass

    def signed_read_url(self, object_key, expires_in):
        return f"https://media.example.test/{object_key}?signed=1"

    def moment_read_url(self, payload):
        self.revision = getattr(self, 'revision', 0) + 1
        return f"https://media.example.test/api/v1/moments/media/content/{self.revision}"

    def resign_read_url(self, token, expires_in):
        return f"https://media.example.test/{token}?expires_in={expires_in}"

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
async def test_image_comment_upload_reply_visibility_and_delete(ctx):
    app, settings = ctx
    factory = app.state.session_factory
    app = create_app(settings, session_factory=factory, avatar_storage=MomentAvatarStorage())
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        owner = {**auth(settings, 'u1'), 'Idempotency-Key': 'image-moment'}
        commenter = {**auth(settings, 'u2'), 'Idempotency-Key': 'image-upload'}
        moment = await client.post('/api/v1/moments', headers=owner, json={'text': 'test', 'visibility': 'FRIENDS'})
        moment_id = moment.json()['id']
        upload = await client.post('/api/v1/moments/media/uploads', headers=commenter, json={'file_name': 'image.png', 'mime_type': 'image/png', 'byte_size': 3})
        upload_id = upload.json()['id']
        uploaded = await client.put(upload.json()['upload_url'], headers={**commenter, 'Content-Type': 'image/png'}, content=b'png')
        assert uploaded.status_code == 204
        completed = await client.post(f'/api/v1/moments/media/uploads/{upload_id}/complete', headers=commenter)
        assert completed.json()['status'] == 'COMPLETED'
        route = f'/api/v1/moments/{moment_id}/comments'
        payload = {'image_upload_ids': [upload_id]}
        created = await client.post(route, headers={**commenter, 'Idempotency-Key': 'image-comment'}, json=payload)
        assert created.status_code == 201, created.text
        assert created.json()['text'] == ''
        assert created.json()['image_urls'][0].startswith('https://media.example.test/api/v1/moments/media/content/')
        replay = await client.post(route, headers={**commenter, 'Idempotency-Key': 'image-comment'}, json=payload)
        assert replay.json()['id'] == created.json()['id']
        reply = await client.post(route, headers={**owner, 'Idempotency-Key': 'emoji-reply'}, json={'text': '😊', 'parent_id': created.json()['id']})
        assert reply.status_code == 201
        assert reply.json()['image_urls'] == []
        assert reply.json()['parent_author']['user_id'] == 'u2'
        visible = await client.get(f'/api/v1/moments/{moment_id}', headers=auth(settings, 'u1'))
        assert visible.json()['comments'][0]['image_cache_keys'] == created.json()['image_cache_keys']
        hidden = await client.get(f'/api/v1/moments/{moment_id}', headers=auth(settings, 'u3'))
        assert hidden.status_code == 404
        hidden_comment = await client.post(route, headers={**auth(settings, 'u3'), 'Idempotency-Key': 'hidden-comment'}, json=payload)
        assert hidden_comment.status_code == 404
        other_moment = await client.post('/api/v1/moments', headers={**commenter, 'Idempotency-Key': 'other-moment'}, json={'text': 'other', 'visibility': 'SELF'})
        collision = await client.post(f"/api/v1/moments/{other_moment.json()['id']}/comments", headers={**commenter, 'Idempotency-Key': 'image-comment'}, json=payload)
        assert collision.status_code == 409
        denied = await client.delete(f"{route}/{created.json()['id']}", headers={**auth(settings, 'u3'), 'Idempotency-Key': 'forbidden-delete'})
        assert denied.status_code == 403
        deleted = await client.delete(f"{route}/{created.json()['id']}", headers={**commenter, 'Idempotency-Key': 'own-delete'})
        assert deleted.status_code == 204
        remaining = await client.get(f'/api/v1/moments/{moment_id}', headers=auth(settings, 'u1'))
        assert [row['id'] for row in remaining.json()['comments']] == [reply.json()['id']]
    from app.modules.moments.models import MomentComment
    with factory() as session:
        stored = session.get(MomentComment, created.json()['id'])
        assert stored.image_object_keys == [f'moments/u2/{upload_id}.png']


@pytest.mark.asyncio
@pytest.mark.parametrize('owner_id,status,purpose', [
    ('u1', 'COMPLETED', 'MOMENT_IMAGE'),
    ('u2', 'PENDING', 'MOMENT_IMAGE'),
    ('u2', 'SCANNING', 'MOMENT_IMAGE'),
    ('u2', 'UPLOADED', 'MOMENT_IMAGE'),
    ('u2', 'COMPLETED', 'MOMENT_COVER'),
])
async def test_image_comment_rejects_unowned_incomplete_or_cover_upload(ctx, owner_id, status, purpose):
    from app.modules.moments.media import MomentMediaUpload
    app, settings = ctx
    now = datetime.now(timezone.utc)
    with app.state.session_factory.begin() as session:
        session.add(MomentMediaUpload(id='upload', owner_id=owner_id, file_name='image.png', mime_type='image/png', byte_size=3, status=status, purpose=purpose, object_key='moments/test.png', idempotency_key='upload', created_at=now, expires_at=now + timedelta(minutes=30)))
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        moment = await client.post('/api/v1/moments', headers={**auth(settings, 'u1'), 'Idempotency-Key': 'moment'}, json={'text': 'test', 'visibility': 'FRIENDS'})
        response = await client.post(f"/api/v1/moments/{moment.json()['id']}/comments", headers={**auth(settings, 'u2'), 'Idempotency-Key': 'comment'}, json={'text': '😊', 'image_upload_ids': ['upload']})
        assert response.status_code == 422
        assert response.json()['error']['code'] == 'MOMENT_COMMENT_MEDIA_INVALID'


@pytest.mark.asyncio
@pytest.mark.parametrize('payload', [{}, {'text': '  '}, {'image_urls': ['https://untrusted.example/image.png']}, {'image_upload_ids': ['missing']}, {'image_upload_ids': ['x'] * 10}])
async def test_image_comment_rejects_empty_arbitrary_or_missing_media(ctx, payload):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        headers = {**auth(settings, 'u1'), 'Idempotency-Key': 'moment'}
        moment = await client.post('/api/v1/moments', headers=headers, json={'text': 'test', 'visibility': 'PUBLIC'})
        response = await client.post(f"/api/v1/moments/{moment.json()['id']}/comments", headers={**headers, 'Idempotency-Key': 'comment'}, json=payload)
        assert response.status_code == 422


@pytest.mark.asyncio
async def test_media_cache_keys_survive_signature_rotation_and_cover_replacement(ctx):
    from app.modules.moments.media import MomentMediaUpload
    from app.modules.moments.models import MomentsPreference
    class RotatingStorage(MomentAvatarStorage):
        revision = 0

        def signed_read_url(self, object_key, expires_in):
            self.revision += 1
            return f'https://media.example.test/{self.revision}/{object_key}?expires_in={expires_in}'

        def resign_read_url(self, token, expires_in):
            return self.signed_read_url(token, expires_in)

    app, settings = ctx
    factory = app.state.session_factory
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(MomentsPreference(user_id='u1', history_range='ALL', personalized_recommendations=True, cover_object_key='moments/covers/u1/first.png', updated_at=now))
        session.add(MomentMediaUpload(id='image', owner_id='u1', file_name='image.png', mime_type='image/png', byte_size=3, status='COMPLETED', purpose='MOMENT_IMAGE', object_key='moments/u1/image.png', idempotency_key='image', created_at=now, expires_at=now + timedelta(minutes=30)))
    app = create_app(settings, session_factory=factory, avatar_storage=RotatingStorage())
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        headers = {**auth(settings, 'u1'), 'Idempotency-Key': 'cache-moment'}
        moment = await client.post('/api/v1/moments', headers=headers, json={'text': 'test', 'visibility': 'SELF', 'image_urls': ['media://moments/u1/image.png']})
        route = f"/api/v1/moments/{moment.json()['id']}"
        await client.post(f'{route}/comments', headers={**headers, 'Idempotency-Key': 'cache-comment'}, json={'image_upload_ids': ['image']})
        first = (await client.get(route, headers=headers)).json()
        second = (await client.get(route, headers=headers)).json()
        assert first['image_urls'] != second['image_urls']
        assert first['image_cache_keys'] == second['image_cache_keys']
        assert len(first['image_cache_keys'][0]) == 64
        assert first['comments'][0]['image_urls'] != second['comments'][0]['image_urls']
        assert '/moments/media/content/' in first['comments'][0]['image_urls'][0]
        assert first['comments'][0]['image_cache_keys'] == second['comments'][0]['image_cache_keys']
        cover_first = (await client.get('/api/v1/moments/preferences', headers=headers)).json()
        cover_second = (await client.get('/api/v1/moments/preferences', headers=headers)).json()
        assert cover_first['cover_url'] != cover_second['cover_url']
        assert cover_first['cover_cache_key'] == cover_second['cover_cache_key']
        with factory.begin() as session:
            session.get(MomentsPreference, 'u1').cover_object_key = 'moments/covers/u1/replaced.png'
        changed = (await client.get('/api/v1/moments/preferences', headers=headers)).json()
        assert changed['cover_cache_key'] != cover_first['cover_cache_key']

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
async def test_identity_projection_is_remark_free(ctx):
    """隐私红线：朋友圈任何投影不得读取或返回好友备注，展示名一律主昵称。"""
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
        author = feed.json()['items'][0]['author']
        assert author == {
            'user_id': 'u1',
            'username': 'alice_id',
            'nickname': 'Alice',
            'display_name': 'Alice',
            'avatar_url': (
                'https://media.example.test/avatars/u1/avatar.png?signed=1'
            ),
        }
        assert 'remark' not in author, '朋友圈响应不得包含备注字段'
        await client.post(
            f'/api/v1/moments/{moment_id}/likes',
            headers={**auth(settings, 'u2'), 'Idempotency-Key': 'identity-like'},
        )
        comment = await client.post(
            f'/api/v1/moments/{moment_id}/comments',
            headers={**auth(settings, 'u2'), 'Idempotency-Key': 'identity-comment'},
            json={'text': '评论身份'},
        )
        assert comment.json()['author']['display_name'] == 'Bob'
        detail = await client.get(
            f'/api/v1/moments/{moment_id}', headers=auth(settings, 'u1')
        )
        assert detail.json()['like_users'][0]['display_name'] == 'Bob'
        assert detail.json()['comments'][0]['author']['display_name'] == 'Bob'
        refreshed_feed = await client.get(
            '/api/v1/moments/feed?mode=latest', headers=auth(settings, 'u1')
        )
        assert refreshed_feed.json()['items'][0]['comments'][0]['text'] == '评论身份'
        assert (
            refreshed_feed.json()['items'][0]['comments'][0]['author'][
                'display_name'
            ]
            == 'Bob'
        )
        notifications = await client.get(
            '/api/v1/moments/notifications', headers=auth(settings, 'u1')
        )
        assert notifications.json()['items'][0]['actor']['display_name'] == 'Bob'
        # 全响应脱敏断言：设置者本人之外的视图不得出现备注文字。
        for payload in (
            feed.json(), detail.json(), comment.json(),
            notifications.json(), refreshed_feed.json(),
        ):
            assert '项目小爱' not in json.dumps(payload, ensure_ascii=False)
            assert '项目小波' not in json.dumps(payload, ensure_ascii=False)

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


@pytest.mark.asyncio
async def test_create_with_images_publishes_immediately_and_shows_in_feed(ctx):
    from app.modules.moments.media import MomentMediaUpload
    original, settings = ctx
    factory = original.state.session_factory
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(MomentMediaUpload(id='post-image', owner_id='u1', file_name='p.jpg', mime_type='image/jpeg', byte_size=3, status='COMPLETED', purpose='MOMENT_IMAGE', object_key='moments/u1/p.jpg', idempotency_key='post-image', created_at=now, expires_at=now+timedelta(minutes=30)))
    app = create_app(settings, session_factory=factory, avatar_storage=MomentAvatarStorage())
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        created = await client.post('/api/v1/moments', headers={**auth(settings,'u1'), 'Idempotency-Key':'img-1'}, json={'text':'带图动态','visibility':'PUBLIC','image_urls':['media://moments/u1/p.jpg']})
        assert created.status_code == 201
        body = created.json()
        assert body['status'] == 'PUBLISHED'
        assert '/moments/media/content/' in body['image_urls'][0]
        feed = (await client.get('/api/v1/moments/feed?mode=latest',headers=auth(settings,'u2'))).json()
        item = next(item for item in feed['items'] if item['id'] == body['id'])
        assert '/moments/media/content/' in item['image_urls'][0]
        assert item['image_cache_keys'] == body['image_cache_keys']

@pytest.mark.asyncio
async def test_storage_resign_recovers_expired_tokens():
    """存储层：过期短签令牌可被无时效解密救活并按新 TTL 重签。"""
    import base64
    from app.integrations.private_storage import LocalPrivateObjectStorage

    storage = LocalPrivateObjectStorage(
        root="storage-test-root",
        signing_secret="test-signing-secret-0123456789",
        public_base_url="https://liuhetong888.com",
    )
    short = storage.signed_read_url("moments/p1.png", 300)
    token = short.split("/content/")[1].split("?")[0]

    # 等价于解密校验失败后的救援路径：直接以无 TTL 解出对象键重签。
    revived = storage.resign_read_url(token, 604800)

    assert "expires_in=604800" in revived
    from urllib.parse import unquote

    object_key = storage._fernet.decrypt(
        unquote(revived.split("/content/")[1].split("?")[0]).encode("ascii")
    ).decode("utf-8")
    assert object_key == "moments/p1.png"

@pytest.mark.asyncio
async def test_new_posts_metadata_baseline_privacy_and_no_global_500_cap(ctx):
    from app.modules.moments.models import Moment
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        baseline = await client.get('/api/v1/moments/new-posts', headers=auth(settings, 'u2'))
        assert baseline.status_code == 200
        assert baseline.json()['items'] == []
        since = baseline.json()['server_time']
        now = datetime.now(timezone.utc)
        with app.state.session_factory.begin() as session:
            for i in range(505):
                session.add(Moment(id=f'noise-{i}', author_id='u3', text='', visibility='PUBLIC', image_urls=[], status='PUBLISHED', idempotency_key=f'noise-{i}', created_at=now + timedelta(microseconds=i)))
            session.add(Moment(id='friend-post', author_id='u1', text='secret body', visibility='FRIENDS', image_urls=['secret'], status='PUBLISHED', idempotency_key='friend-post', created_at=now))
            session.add(Moment(id='self-post', author_id='u2', text='', visibility='PUBLIC', image_urls=[], status='PUBLISHED', idempotency_key='self-post', created_at=now))
        result = await client.get('/api/v1/moments/new-posts', params={'since': since}, headers=auth(settings, 'u2'))
        assert result.status_code == 200
        assert [item['id'] for item in result.json()['items']] == ['friend-post']
        assert set(result.json()['items'][0]) == {'id', 'created_at'}

@pytest.mark.asyncio
async def test_new_posts_cursor_auth_and_directional_privacy(ctx):
    from app.modules.moments.models import Moment
    app, settings = ctx
    now = datetime.now(timezone.utc)
    with app.state.session_factory.begin() as session:
        for i in range(105):
            session.add(Moment(id=f'post-{i:03}', author_id='u1', text='', visibility='FRIENDS', image_urls=[], status='PUBLISHED', idempotency_key=f'post-{i}', created_at=now))
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        assert (await client.get('/api/v1/moments/new-posts')).status_code == 401
        params = {'since': (now - timedelta(seconds=1)).isoformat()}
        first = (await client.get('/api/v1/moments/new-posts', params=params, headers=auth(settings, 'u2'))).json()
        second = (await client.get('/api/v1/moments/new-posts', params={**params, 'cursor': first['next_cursor']}, headers=auth(settings, 'u2'))).json()
        assert len(first['items']) == 100
        assert len(second['items']) == 5
        assert len({i['id'] for i in first['items'] + second['items']}) == 105
        with app.state.session_factory.begin() as session:
            session.add(ContactProfile(id='hidden-profile', owner_id='u2', contact_id='u1', remark='', moments_permission='HIDE_THEIRS'))
        hidden = (await client.get('/api/v1/moments/new-posts', params=params, headers=auth(settings, 'u2'))).json()
        assert hidden['items'] == []
