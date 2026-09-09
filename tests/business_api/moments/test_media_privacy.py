from datetime import datetime, timedelta, timezone
import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete
from test_moments_api import auth, ctx
from app.main import create_app
from app.integrations.private_storage import LocalPrivateObjectStorage
from app.modules.moments.media import MomentMediaUpload
from app.modules.moments.models import Moment, MomentComment, MomentsPreference
from app.modules.friendship.models import Friendship

@pytest.mark.asyncio
@pytest.mark.parametrize('revoke', ['excluded', 'entry', 'range', 'friend'])
async def test_media_capabilities_recheck_privacy(ctx, tmp_path, revoke):
    original, settings = ctx
    factory = original.state.session_factory
    storage = LocalPrivateObjectStorage(root=str(tmp_path), signing_secret='x'*32, public_base_url='http://test')
    key = 'moments/u1/photo.jpg'
    storage.put(key, b'photo')
    legacy = storage.signed_read_url(key, 604800)
    now = datetime.now(timezone.utc)
    with factory.begin() as s:
        s.add(MomentMediaUpload(id='upload', owner_id='u1', file_name='photo.jpg', mime_type='image/jpeg', byte_size=5, status='COMPLETED', object_key=key, purpose='MOMENT_IMAGE', idempotency_key='up', created_at=now, expires_at=now+timedelta(days=1)))
        s.add(Moment(id='post', author_id='u1', text='', visibility='FRIENDS', image_urls=[legacy], status='PUBLISHED', idempotency_key='post', created_at=now-timedelta(days=10)))
        s.add(MomentComment(id='comment', moment_id='post', user_id='u1', text='', image_object_keys=[key], idempotency_key='comment', created_at=now))
    app = create_app(settings, session_factory=factory, avatar_storage=storage)
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as c:
        dto = (await c.get('/api/v1/moments/post', headers=auth(settings,'u2'))).json()
        urls = dto['image_urls'] + dto['comments'][0]['image_urls']
        assert all('/moments/media/content/' in url for url in urls)
        for url in urls:
            assert (await c.get(url)).content == b'photo'
            assert (await c.get(url+'tampered')).status_code == 404
        assert (await c.get(legacy)).status_code == 404
        foreign = await c.post('/api/v1/moments', headers={**auth(settings,'u2'),'Idempotency-Key':'launder'}, json={'visibility':'FRIENDS','image_urls':[legacy]})
        assert foreign.status_code == 422
        arbitrary = await c.post('/api/v1/moments', headers={**auth(settings,'u1'),'Idempotency-Key':'arbitrary'}, json={'visibility':'FRIENDS','image_urls':['https://example.org/photo.jpg']})
        assert arbitrary.status_code == 422
        with factory.begin() as s:
            if revoke == 'friend':
                s.execute(delete(Friendship))
            else:
                s.add(MomentsPreference(user_id='u1', history_range='THREE_DAYS' if revoke=='range' else 'ALL', personalized_recommendations=True, profile_entry_enabled=revoke!='entry', excluded_user_ids=['u2'] if revoke=='excluded' else [], updated_at=now))
        for url in urls:
            assert (await c.get(url)).status_code == 404
        own = (await c.get('/api/v1/moments/post',headers=auth(settings,'u1'))).json()
        assert own['image_cache_keys'] == dto['image_cache_keys']
        assert (await c.get(own['image_urls'][0])).status_code == 200


def test_preview_does_not_query_relationships_per_hidden_post(ctx):
    from sqlalchemy import event
    from app.modules.moments.service import MomentsService
    app, _ = ctx
    factory = app.state.session_factory
    now = datetime.now(timezone.utc)
    with factory.begin() as s:
        s.add(MomentsPreference(user_id='u1', history_range='THREE_DAYS', personalized_recommendations=True, profile_entry_enabled=True, excluded_user_ids=[], updated_at=now))
        for i in range(200):
            s.add(Moment(id=f'hidden-{i}', author_id='u1', text='', visibility='SELF', image_urls=[], status='PUBLISHED', idempotency_key=f'hidden-{i}', created_at=now))
        s.add(Moment(id='visible', author_id='u1', text='', visibility='FRIENDS', image_urls=[], status='PUBLISHED', idempotency_key='visible', created_at=now-timedelta(days=1)))
    statements = []
    engine = factory.kw['bind']
    def count(connection, cursor, statement, parameters, context, executemany):
        statements.append(statement)
    event.listen(engine, 'before_cursor_execute', count)
    try:
        result = MomentsService(factory).profile_preview('u2', 'u1')
    finally:
        event.remove(engine, 'before_cursor_execute', count)
    assert [item['id'] for item in result['items']] == ['visible']
    assert len(statements) < 20
    assert any('moments.created_at >=' in statement for statement in statements)

@pytest.mark.asyncio
async def test_owner_upload_capability_creates_post_and_expiry_is_fixed(ctx, tmp_path):
    from urllib.parse import urlparse
    original, settings = ctx
    storage = LocalPrivateObjectStorage(root=str(tmp_path), signing_secret='x'*32, public_base_url='http://test')
    app = create_app(settings, session_factory=original.state.session_factory, avatar_storage=storage)
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as c:
        headers = {**auth(settings, 'u1'), 'Idempotency-Key': 'upload'}
        upload = (await c.post('/api/v1/moments/media/uploads', headers=headers, json={'file_name':'p.jpg','mime_type':'image/jpeg','byte_size':3})).json()
        assert (await c.put(upload['upload_url'], headers={**headers,'Content-Type':'image/jpeg'},content=b'jpg')).status_code == 204
        complete = (await c.post(f"/api/v1/moments/media/uploads/{upload['id']}/complete",headers=headers)).json()
        assert (await c.get(complete['media_url'])).content == b'jpg'
        payload = {'visibility':'FRIENDS','image_urls':[complete['media_url']]}
        assert (await c.post('/api/v1/moments',headers={**auth(settings,'u2'),'Idempotency-Key':'foreign'},json=payload)).status_code == 422
        posted = await c.post('/api/v1/moments',headers={**headers,'Idempotency-Key':'post'},json=payload)
        assert posted.status_code == 201
        url = posted.json()['image_urls'][0]
        assert (await c.get(url)).content == b'jpg'
        token = urlparse(url).path.rsplit('/',1)[1]
        expired = storage._fernet.encrypt_at_time(storage.decode_key(token).encode(), int(datetime.now(timezone.utc).timestamp())-400).decode()
        assert (await c.get('/api/v1/moments/media/content/'+expired+'?expires_in=604800')).status_code == 404
