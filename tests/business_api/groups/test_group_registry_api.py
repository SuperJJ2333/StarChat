"""ADR-0079：群主转让/注册 API 契约（错误码、权限、任期核验）。"""
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

ALICE, BOB = '@alice:x', '@bob:x'
ROOM = '!reg:x'


def bearer(settings, user):
    now = datetime.now(timezone.utc)
    token = jwt.encode({'sub': user, 'iss': settings.jwt_issuer, 'iat': int(now.timestamp()),
        'exp': int((now + timedelta(minutes=5)).timestamp())}, settings.jwt_secret, algorithm='HS256')
    return {'Authorization': f'Bearer {token}', 'Idempotency-Key': f'k-{user}-{now.timestamp()}'}


class FakeGateway:
    def __init__(self):
        self.power_users = {ALICE: 100, BOB: 0}
        self.members = {ALICE, BOB}

    def get_room_state(self, room_id):
        return [{'type': 'm.room.power_levels', 'content': {'users': self.power_users}}]

    def get_room_members(self, room_id):
        return self.members


@pytest.mark.asyncio
async def test_register_transfer_owner_view_contract():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        for user_id, mxid in (('u1', ALICE), ('u2', BOB)):
            session.add(User(id=user_id, username=user_id, username_normalized=user_id,
                email=f'{user_id}@x.test', email_normalized=f'{user_id}@x.test', password_hash='x',
                status=AccountStatus.ACTIVE, matrix_user_id=mxid, created_at=now, updated_at=now))
    settings = Settings(_env_file=None, environment='test', jwt_secret='x' * 32)
    gateway = FakeGateway()
    app = create_app(settings, session_factory=factory, matrix_gateway=gateway)
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        # 注册建群（u1 为创建者）
        registered = await client.post('/api/v1/groups/register', headers=bearer(settings, 'u1'), json={'room_id': ROOM})
        assert registered.status_code == 200
        assert registered.json()['tenure_source'] == 'creation'
        # 未满任期的冷却约束在满 10 人时才触发（当前 2 人，直接允许转让）
        transferred = await client.post(f'/api/v1/groups/{ROOM}/transfer-owner',
            headers=bearer(settings, 'u1'), json={'new_owner_user_id': 'u2'})
        assert transferred.status_code == 503
        assert transferred.json()['error']['code'] == 'GROUP_TRANSFER_UNAVAILABLE'
        # Until durable Matrix coordination is implemented, no financial owner
        # or tenure may move merely because the endpoint was requested.
        view = await client.get(f'/api/v1/groups/{ROOM}/owner', headers=bearer(settings, 'u1'))
        assert view.status_code == 200
        assert view.json()['owner_user_id'] == 'u1'
        assert view.json()['owner_desync'] is False
    engine.dispose()
