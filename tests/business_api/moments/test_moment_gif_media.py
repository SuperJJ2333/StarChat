import io

import pytest
from httpx import ASGITransport, AsyncClient
from PIL import Image

from app.main import create_app
from app.core.errors import AppError
from app.modules.moments.media import validate_gif
from test_moments_api import auth, ctx


class GifStorage:
    def __init__(self):
        self.objects = {}
        self.tokens = {}

    def put(self, key, content):
        self.objects[key] = content

    def get(self, key):
        return self.objects[key]

    def moment_read_url(self, payload):
        token = str(len(self.tokens))
        self.tokens[token] = payload
        return '/api/v1/moments/media/content/' + token

    def decode_key(self, token, ttl=300):
        return self.tokens[token]


def animated_gif():
    output = io.BytesIO()
    Image.new('RGB', (2, 2), 'red').save(
        output, format='GIF', save_all=True,
        append_images=[Image.new('RGB', (2, 2), 'blue')],
        duration=120, loop=0,
    )
    return output.getvalue()


@pytest.mark.asyncio
async def test_gif_comment_preserves_animation_and_live_visibility(ctx):
    app, settings = ctx
    storage = GifStorage()
    app = create_app(settings, session_factory=app.state.session_factory, avatar_storage=storage)
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        owner = {**auth(settings, 'u1'), 'Idempotency-Key': 'gif-moment'}
        friend = {**auth(settings, 'u2'), 'Idempotency-Key': 'gif-upload'}
        moment = await client.post('/api/v1/moments', headers=owner, json={'text': 'fixture', 'visibility': 'FRIENDS'})
        moment_id = moment.json()['id']
        content = animated_gif()
        upload = await client.post('/api/v1/moments/media/uploads', headers=friend,
                                   json={'file_name': 'animation.gif', 'mime_type': 'image/gif', 'byte_size': len(content)})
        assert upload.status_code == 201, upload.text
        assert (await client.put(upload.json()['upload_url'], headers={**friend, 'Content-Type': 'image/gif'}, content=content)).status_code == 204
        upload_id = upload.json()['id']
        assert (await client.post(f'/api/v1/moments/media/uploads/{upload_id}/complete', headers=friend)).json()['status'] == 'COMPLETED'
        route = f'/api/v1/moments/{moment_id}/comments'
        comment = await client.post(route, headers={**friend, 'Idempotency-Key': 'gif-comment'}, json={'text': '😀', 'image_upload_ids': [upload_id]})
        assert comment.status_code == 201, comment.text
        url = comment.json()['image_urls'][0]
        image = await client.get(url)
        assert image.status_code == 200
        assert image.headers['content-type'] == 'image/gif'
        assert image.content == content
        assert Image.open(io.BytesIO(image.content)).n_frames == 2
        assert (await client.get(f'/api/v1/moments/{moment_id}', headers=auth(settings, 'u3'))).status_code == 404
        await client.put('/api/v1/moments/preferences', headers=owner,
                         json={'history_range': 'ALL', 'personalized_recommendations': True, 'excluded_user_ids': ['u2']})
        assert (await client.get(url)).status_code == 404


@pytest.mark.asyncio
@pytest.mark.parametrize('content', [b'not a gif', b'GIF89a\x00\x00\x00\x00', b'GIF89a\xff\xff\xff\xff' + b'\x00' * 20])
async def test_gif_rejects_invalid_or_oversized_canvas_before_storage(ctx, content):
    app, settings = ctx
    storage = GifStorage()
    app = create_app(settings, session_factory=app.state.session_factory, avatar_storage=storage)
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        headers = {**auth(settings, 'u1'), 'Idempotency-Key': 'bad-gif'}
        upload = await client.post('/api/v1/moments/media/uploads', headers=headers,
                                   json={'file_name': 'bad.gif', 'mime_type': 'image/gif', 'byte_size': len(content)})
        assert upload.status_code == 201
        result = await client.put(upload.json()['upload_url'], headers={**headers, 'Content-Type': 'image/gif'}, content=content)
        assert result.status_code == 422
        assert storage.objects == {}


def test_openapi_advertises_gif(ctx):
    app, _ = ctx
    content = app.openapi()['paths']['/api/v1/moments/media/content/{token}']['get']['responses']['200']['content']
    assert 'image/gif' in content


@pytest.mark.parametrize('cut', [10, 20, 30])
def test_truncated_later_gif_frames_are_rejected(cut):
    with pytest.raises(AppError) as error:
        validate_gif(animated_gif()[:-cut])
    assert error.value.status_code == 422


@pytest.mark.parametrize('mutation', ['missing-trailer', 'frame-outside-canvas'])
def test_invalid_gif_container_is_rejected(mutation):
    content = bytearray(animated_gif())
    if mutation == 'missing-trailer':
        assert content[-1] == 0x3b
        content.pop()
    else:
        descriptor = content.index(0x2c)
        content[descriptor + 1:descriptor + 3] = (2).to_bytes(2, 'little')
    with pytest.raises(AppError) as error:
        validate_gif(bytes(content))
    assert error.value.status_code == 422


@pytest.mark.asyncio
@pytest.mark.parametrize('kind', ['media', 'cover'])
async def test_upload_stream_stops_as_soon_as_limit_is_exceeded(ctx, kind):
    app, settings = ctx
    storage = GifStorage()
    app = create_app(settings, session_factory=app.state.session_factory, avatar_storage=storage)
    consumed = []

    async def chunks():
        for index, chunk in enumerate([b'a' * (20 * 1024 * 1024), b'b', b'never-read']):
            consumed.append(index)
            yield chunk

    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        headers = {**auth(settings, 'u1'), 'Idempotency-Key': 'stream-limit'}
        upload = await client.post(f'/api/v1/moments/{kind}/uploads', headers=headers,
                                   json={'file_name': 'image.jpg', 'mime_type': 'image/jpeg', 'byte_size': 1})
        assert upload.status_code == 201
        response = await client.put(upload.json()['upload_url'],
                                    headers={**headers, 'Content-Type': 'image/jpeg'}, content=chunks())
        assert response.status_code == 422
        assert consumed == [0, 1]
        assert storage.objects == {}


@pytest.mark.asyncio
async def test_gif_cannot_bypass_validation_by_declaring_jpeg(ctx):
    app, settings = ctx
    storage = GifStorage()
    app = create_app(settings, session_factory=app.state.session_factory, avatar_storage=storage)
    content = animated_gif()
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        headers = {**auth(settings, 'u1'), 'Idempotency-Key': 'disguised-gif'}
        upload = await client.post('/api/v1/moments/media/uploads', headers=headers,
                                   json={'file_name': 'image.gif', 'mime_type': 'image/jpeg', 'byte_size': len(content)})
        response = await client.put(upload.json()['upload_url'],
                                    headers={**headers, 'Content-Type': 'image/jpeg'}, content=content)
        assert response.status_code == 422
        assert storage.objects == {}
