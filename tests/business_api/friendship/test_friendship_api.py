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

def bearer(settings, user):
    now = datetime.now(timezone.utc)
    token = jwt.encode({'sub': user, 'iss': settings.jwt_issuer, 'iat': int(now.timestamp()), 'exp': int((now + timedelta(minutes=5)).timestamp())}, settings.jwt_secret, algorithm='HS256')
    return {'Authorization': f'Bearer {token}'}

@pytest.fixture
def ctx():
    engine = create_engine('sqlite+pysqlite:///:memory:', connect_args={'check_same_thread': False}, poolclass=StaticPool)
    Base.metadata.create_all(engine); factory = create_session_factory(engine); now = datetime.now(timezone.utc)
    with factory.begin() as session:
        for user_id, name in [('u1', 'alice'), ('u2', 'bob')]:
            session.add(User(id=user_id, username=name, username_normalized=name, email=f'{name}@x.test', email_normalized=f'{name}@x.test', password_hash='x', status=AccountStatus.ACTIVE, created_at=now, updated_at=now))
    settings = Settings(_env_file=None, environment='test', jwt_secret='x' * 32)
    yield create_app(settings, session_factory=factory), settings

@pytest.mark.asyncio
async def test_request_accept_list_block_and_search(ctx):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        request = await client.post('/api/v1/friends/requests', headers={**bearer(settings, 'u1'), 'Idempotency-Key': 'r1'}, json={'target_user_id': 'u2', 'message': '你好'})
        assert request.status_code == 201
        accepted = await client.post(f"/api/v1/friends/requests/{request.json()['id']}/accept", headers={**bearer(settings, 'u2'), 'Idempotency-Key': 'a1'})
        assert accepted.status_code == 200
        friends = await client.get('/api/v1/friends', headers=bearer(settings, 'u1'))
        assert friends.json()['items'][0]['user_id'] == 'u2'
        blocked = await client.post('/api/v1/blocks', headers={**bearer(settings, 'u1'), 'Idempotency-Key': 'b1'}, json={'user_id': 'u2'})
        assert blocked.status_code == 201
        search = await client.get('/api/v1/users/search?q=bob', headers=bearer(settings, 'u1'))
        assert search.json()['items'] == []
