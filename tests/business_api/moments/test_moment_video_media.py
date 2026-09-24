import pytest
from httpx import ASGITransport, AsyncClient
from test_moments_api import auth, ctx

from app.main import create_app
from app.integrations.private_storage import LocalPrivateObjectStorage


def box(kind, payload):
    return (8 + len(payload)).to_bytes(4, 'big') + kind + payload


VIDEO = box(b'ftyp', b'isom\0\0\0\0isommp42') + box(b'moov', box(b'trak', b'video')) + box(b'mdat', b'frame')


@pytest.mark.asyncio
async def test_video_upload_publish_projection_ownership_and_revocation(ctx, tmp_path):
    original, settings = ctx
    storage = LocalPrivateObjectStorage(root=str(tmp_path), signing_secret='x'*32, public_base_url='http://test')
    app = create_app(settings, session_factory=original.state.session_factory, avatar_storage=storage)
    headers = {**auth(settings, 'u1'), 'Idempotency-Key': 'video'}
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as c:
        data = {'file_name': 'clip.mp4', 'mime_type': 'video/mp4', 'byte_size': len(VIDEO)}
        begun = await c.post('/api/v1/moments/media/uploads', headers=headers, json=data)
        assert begun.status_code == 201
        upload = begun.json()
        assert (await c.post('/api/v1/moments/media/uploads', headers=headers, json=data)).json()['id'] == upload['id']
        assert (await c.put(upload['upload_url'], headers={**auth(settings,'u2'), 'Content-Type':'video/mp4'}, content=VIDEO)).status_code == 404
        assert (await c.put(upload['upload_url'], headers={**headers, 'Content-Type':'video/mp4'}, content=b'x'*len(VIDEO))).status_code == 422
        assert (await c.put(upload['upload_url'], headers={**headers, 'Content-Type':'video/mp4'}, content=VIDEO)).status_code == 204
        complete = await c.post(f"/api/v1/moments/media/uploads/{upload['id']}/complete", headers=headers)
        assert complete.status_code == 200
        assert len(complete.json()['media_cache_key']) == 64
        url = complete.json()['media_url']
        assert (await c.get(url)).content == VIDEO
        payload = {'visibility': 'FRIENDS', 'video_urls': [url]}
        assert (await c.put('/api/v1/moments/draft', headers=auth(settings,'u2'), json={'payload':payload})).status_code == 422
        saved_draft = await c.put('/api/v1/moments/draft', headers=headers,
                                  json={'payload': {**payload, 'video_cache_keys': ['0' * 64]}})
        assert saved_draft.status_code == 200
        assert 'video_cache_keys' not in saved_draft.json()
        draft = (await c.get('/api/v1/moments/draft', headers=headers)).json()
        assert draft['video_cache_keys'] == [complete.json()['media_cache_key']]
        assert (await c.get(draft['video_urls'][0])).content == VIDEO
        renewed_draft = (await c.get('/api/v1/moments/draft', headers=headers)).json()
        assert renewed_draft['video_cache_keys'] == draft['video_cache_keys']
        assert (await c.get(renewed_draft['video_urls'][0])).content == VIDEO
        assert (await c.post('/api/v1/moments', headers={**auth(settings,'u2'), 'Idempotency-Key':'foreign'}, json=payload)).status_code == 422
        assert (await c.post('/api/v1/moments', headers={**headers, 'Idempotency-Key':'disguise'}, json={'visibility':'PUBLIC','image_urls':[url]})).status_code == 422
        posted = await c.post('/api/v1/moments', headers={**headers, 'Idempotency-Key':'post'}, json=payload)
        assert posted.status_code == 201
        post = posted.json()
        assert post['image_urls'] == []
        assert post['image_cache_keys'] == []
        assert len(post['video_urls']) == len(post['video_cache_keys']) == 1
        assert post['video_cache_keys'][0] == complete.json()['media_cache_key']
        viewer = (await c.get('/api/v1/moments/' + post['id'], headers=auth(settings,'u2'))).json()
        media = await c.get(viewer['video_urls'][0])
        assert media.content == VIDEO
        assert media.headers['content-type'] == 'video/mp4'
        assert media.headers['cache-control'] == 'private, no-store'
        assert viewer['video_cache_keys'] == post['video_cache_keys']
        assert (await c.post('/api/v1/moments', headers={**headers, 'Idempotency-Key':'limit'}, json={**payload,'video_urls':[url]*10})).status_code == 422
        assert (await c.post('/api/v1/moments/'+post['id']+'/comments', headers={**headers,'Idempotency-Key':'comment'}, json={'image_upload_ids':[upload['id']]})).status_code == 422
        await c.patch('/api/v1/moments/'+post['id']+'/visibility', headers=headers, json={'visibility':'SELF'})
        assert (await c.get(viewer['video_urls'][0])).status_code == 404


@pytest.mark.asyncio
async def test_image_cannot_be_published_as_video_or_saved_in_video_draft(ctx):
    app, settings = ctx
    headers={**auth(settings,'u1'),'Idempotency-Key':'image'}
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as c:
        upload=(await c.post('/api/v1/moments/media/uploads',headers=headers,json={'file_name':'p.jpg','mime_type':'image/jpeg','byte_size':3})).json()
        await c.put(upload['upload_url'],headers={**headers,'Content-Type':'image/jpeg'},content=b'jpg')
        complete=(await c.post(f"/api/v1/moments/media/uploads/{upload['id']}/complete",headers=headers)).json()
        payload={'visibility':'PUBLIC','video_urls':[complete['media_url']]}
        assert (await c.post('/api/v1/moments',headers=headers,json=payload)).status_code==422
        assert (await c.put('/api/v1/moments/draft',headers=headers,json={'payload':payload})).status_code==422


@pytest.mark.parametrize('content,mime', [
    (VIDEO[:-1], 'video/mp4'),
    (VIDEO, 'video/quicktime'),
    (box(b'ftyp',b'heic\0\0\0\0heic')+box(b'moov',b'x')+box(b'mdat',b'x'),'video/mp4'),
    (box(b'ftyp',b'isom\0\0\0\0')+box(b'mdat',b'x'),'video/mp4'),
])
def test_video_container_rejects_damage_and_disguised_types(content, mime):
    from app.core.errors import AppError
    from app.modules.moments.media import validate_video_container
    with pytest.raises(AppError):
        validate_video_container(content,mime)


@pytest.mark.asyncio
@pytest.mark.parametrize('field,value', [(field, value) for field in ('image_urls','video_urls') for value in (None, 1, 'url', {}, [None])])
async def test_draft_rejects_malformed_attachment_lists(ctx, field, value):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        response = await client.put('/api/v1/moments/draft', headers=auth(settings,'u1'), json={'payload':{field:value}})
        assert response.status_code == 422


@pytest.mark.asyncio
@pytest.mark.parametrize('mime,size,path,expected', [
    ('video/mp4', 20*1024*1024, 'media', 201),
    ('video/quicktime', 100, 'media', 201),
    ('video/mp4', 20*1024*1024+1, 'media', 422),
    ('video/webm', 100, 'media', 422),
    ('video/mp4', 100, 'cover', 422),
])
async def test_video_begin_boundaries(ctx, mime, size, path, expected):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as c:
        result = await c.post(f'/api/v1/moments/{path}/uploads', headers={**auth(settings,'u1'),'Idempotency-Key':'boundary'}, json={'file_name':'clip.mp4','mime_type':mime,'byte_size':size})
        assert result.status_code == expected
