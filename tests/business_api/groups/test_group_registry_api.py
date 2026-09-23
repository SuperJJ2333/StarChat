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

    def send_room_state_as_user(self, actor, room_id, event_type, content):
        assert actor == ALICE
        self.power_users = dict(content['users'])


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


@pytest.mark.asyncio
async def test_unregistered_transfer_timeline_discovers_authoritative_owner_without_inventing_tenure():
    from sqlalchemy import select
    from app.modules.groups.models import BusinessGroup, GroupTransferIntent

    engine = create_engine('sqlite+pysqlite:///:memory:',
        connect_args={'check_same_thread': False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(User(id='legacy-member', username='legacy-member',
            username_normalized='legacy-member', email='member@x.test',
            email_normalized='member@x.test', password_hash='unused',
            status=AccountStatus.ACTIVE, matrix_user_id=ALICE,
            created_at=now, updated_at=now))
    gateway = FakeGateway()
    settings = Settings(_env_file=None, environment='test', jwt_secret='x' * 32)
    app = create_app(settings, session_factory=factory, matrix_gateway=gateway)
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
            route = f'/api/v1/groups/{ROOM}/transfer-intents'
            assert (await client.get(route)).status_code == 401
            missing = await client.get(route, headers=bearer(settings, 'legacy-member'))
            assert missing.status_code == 200, missing.text
            assert missing.json()['items'] == []
        with factory() as session:
            group = session.scalar(select(BusinessGroup))
            assert group.owner_user_id == 'legacy-member'
            assert group.owner_since is None
            assert group.tenure_source is None
            assert session.scalar(select(GroupTransferIntent)) is None
        assert settings.group_transfer_coordination_enabled is False
    finally:
        engine.dispose()


@pytest.mark.asyncio
@pytest.mark.parametrize('authority', ['outsider', 'unavailable', 'ambiguous'])
async def test_legacy_timeline_does_not_register_without_authorized_authority(authority):
    from sqlalchemy import select
    from app.modules.groups.models import BusinessGroup

    engine = create_engine('sqlite+pysqlite:///:memory:',
        connect_args={'check_same_thread': False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(User(id='u1', username='u1', username_normalized='u1',
            email='u1@x.test', email_normalized='u1@x.test', password_hash='x',
            status=AccountStatus.ACTIVE, matrix_user_id=ALICE, created_at=now, updated_at=now))
    gateway = FakeGateway()
    if authority == 'outsider':
        gateway.members.remove(ALICE)
    elif authority == 'ambiguous':
        gateway.power_users[BOB] = 100
    else:
        def unavailable(_):
            raise RuntimeError('offline')
        gateway.get_room_members = unavailable
    settings = Settings(_env_file=None, environment='test', jwt_secret='x' * 32)
    app = create_app(settings, session_factory=factory, matrix_gateway=gateway)
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
            response = await client.get(f'/api/v1/groups/{ROOM}/transfer-intents', headers=bearer(settings, 'u1'))
            assert response.status_code == (403 if authority == 'outsider' else 503)
        with factory() as session:
            assert session.scalar(select(BusinessGroup)) is None
    finally:
        engine.dispose()


@pytest.mark.asyncio
@pytest.mark.parametrize('joined', [9, 10])
async def test_discovered_legacy_group_transfer_preserves_unknown_tenure_rule(joined):
    from app.modules.groups.models import BusinessGroup

    engine = create_engine('sqlite+pysqlite:///:memory:',
        connect_args={'check_same_thread': False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        for user_id, matrix_id in [('u1', ALICE), ('u2', BOB)]:
            session.add(User(id=user_id, username=user_id, username_normalized=user_id,
                email=f'{user_id}@x.test', email_normalized=f'{user_id}@x.test', password_hash='x',
                status=AccountStatus.ACTIVE, matrix_user_id=matrix_id, created_at=now, updated_at=now))
    gateway = FakeGateway()
    gateway.members.update(f'@extra{i}:x' for i in range(joined - 2))
    settings = Settings(_env_file=None, environment='test', jwt_secret='x' * 32,
        group_transfer_coordination_enabled=True)
    app = create_app(settings, session_factory=factory, matrix_gateway=gateway)
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
            assert (await client.get(f'/api/v1/groups/{ROOM}/transfer-intents',
                headers=bearer(settings, 'u1'))).status_code == 200
            response = await client.post(f'/api/v1/groups/{ROOM}/transfer-owner',
                headers=bearer(settings, 'u1'), json={'new_owner_user_id': 'u2'})
            if joined == 9:
                assert response.status_code == 200, response.text
                assert response.json()['stage'] == 'COMPLETED'
                assert response.json()['owner_user_id'] == 'u2'
                assert gateway.power_users == {ALICE: 0, BOB: 100}
            else:
                assert response.status_code == 409, response.text
                assert response.json()['error']['code'] == 'OWNER_TENURE_UNPROVEN'
                assert '管理员' in response.json()['error']['message']
                assert gateway.power_users == {ALICE: 100, BOB: 0}
                with factory() as session:
                    assert session.get(BusinessGroup, ROOM).owner_since is None
    finally:
        engine.dispose()
