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

def auth(settings, user):
    now = datetime.now(timezone.utc)
    token = jwt.encode({'sub': user, 'iss': settings.jwt_issuer, 'iat': int(now.timestamp()), 'exp': int((now + timedelta(minutes=5)).timestamp())}, settings.jwt_secret, algorithm='HS256')
    return {'Authorization': f'Bearer {token}'}

@pytest.fixture
def ctx():
    engine = create_engine('sqlite+pysqlite:///:memory:', connect_args={'check_same_thread': False}, poolclass=StaticPool)
    Base.metadata.create_all(engine); factory = create_session_factory(engine); now = datetime.now(timezone.utc)
    with factory.begin() as session:
        for user_id, name in [('u1', 'alice'), ('u2', 'bob')]:
            session.add(User(id=user_id, username=name, username_normalized=name, email=f'{name}@x', email_normalized=f'{name}@x', password_hash='x', status=AccountStatus.ACTIVE, created_at=now, updated_at=now))
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
        liked = await client.post(f'/api/v1/moments/{moment_id}/likes', headers={**auth(settings, 'u2'), 'Idempotency-Key': 'l1'})
        assert liked.status_code == 201
        comment = await client.post(f'/api/v1/moments/{moment_id}/comments', headers={**auth(settings, 'u2'), 'Idempotency-Key': 'c1'}, json={'text': '真漂亮'})
        assert comment.status_code == 201
        search = await client.get('/api/v1/moments/search?q=香港', headers=auth(settings, 'u2'))
        assert search.json()['items'][0]['id'] == moment_id
