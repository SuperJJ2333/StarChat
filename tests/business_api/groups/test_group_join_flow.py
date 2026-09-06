"""群聊加入协调测试：auto-join 授权校验 + 群二维码令牌生命周期 + 审批。

FakeMatrixGateway 完整模拟 Synapse 房间状态与 admin join——不依赖
真实 Matrix；断言服务端绝不凭客户端 room_id 盲加。
"""
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

ALICE = '@alice:matrix.example.test'
BOB = '@bob:matrix.example.test'
CAROL = '@carol:matrix.example.test'
DAVE = '@dave:matrix.example.test'

ROOM = '!group:matrix.example.test'
ROOM2 = '!other:matrix.example.test'


@pytest.mark.asyncio
async def test_qr_issue_replay_and_revoke_conflict_do_not_mutate(env):
    from sqlalchemy import select
    from app.modules.groups.models import GroupJoinToken
    app, settings, gateway, factory = env
    gateway.set_room(ROOM, [gateway.member_event(ALICE, 'join'), gateway.power_event({ALICE: 100})])
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        headers = {**bearer(settings, 'u1'), 'Idempotency-Key': 'issue-replay'}
        first = await client.post(f'/api/v1/groups/{ROOM}/join-tokens', headers=headers)
        replay = await client.post(f'/api/v1/groups/{ROOM}/join-tokens', headers=headers)
        assert replay.status_code == 409
        with factory() as session:
            assert len(session.scalars(select(GroupJoinToken)).all()) == 1
        second = await client.post(f'/api/v1/groups/{ROOM}/join-tokens', headers={**headers, 'Idempotency-Key': 'issue-second'})
        token1 = first.json()['token_payload'].split('/')[-1]
        token2 = second.json()['token_payload'].split('/')[-1]
        revoke_headers = {**headers, 'Idempotency-Key': 'revoke-conflict'}
        assert (await client.post(f'/api/v1/groups/join-tokens/{token1}/revoke', headers=revoke_headers)).status_code == 200
        assert (await client.post(f'/api/v1/groups/join-tokens/{token2}/revoke', headers=revoke_headers)).status_code == 409
        assert (await client.get('/api/v1/groups/join-info', params={'token': token2}, headers=headers)).status_code == 200


@pytest.mark.asyncio
async def test_qr_failed_join_can_retry_same_key_and_replay_actual_result(env):
    app, settings, gateway, _ = env
    gateway.set_room(ROOM, [gateway.member_event(ALICE, 'join'), gateway.power_event({ALICE: 100})])
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        issued = await client.post(f'/api/v1/groups/{ROOM}/join-tokens', headers={**bearer(settings, 'u1'), 'Idempotency-Key': 'issue'})
        token = issued.json()['token_payload'].split('/')[-1]
        headers = {**bearer(settings, 'u2'), 'Idempotency-Key': 'retry'}
        gateway.fail_join_for.add(BOB)
        assert (await client.post('/api/v1/groups/join-tokens/redeem', headers=headers, json={'token': token})).status_code == 502
        gateway.fail_join_for.clear()
        response = await client.post('/api/v1/groups/join-tokens/redeem', headers=headers, json={'token': token})
        assert response.json() == {'status': 'joined', 'room_id': ROOM}
        replay = await client.post('/api/v1/groups/join-tokens/redeem', headers=headers, json={'token': token})
        assert replay.json() == response.json()
        assert len(gateway.joins) == 1


@pytest.mark.asyncio
@pytest.mark.parametrize('invalid_state', ['banned', 'issuer_left', 'issuer_demoted'])
async def test_qr_redeem_preserves_bans_and_current_inviter_authority(env, invalid_state):
    app, settings, gateway, _ = env
    gateway.set_room(ROOM, [gateway.member_event(ALICE, 'join'), gateway.power_event({ALICE: 100})])
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        issued = await client.post(f'/api/v1/groups/{ROOM}/join-tokens', headers={**bearer(settings, 'u1'), 'Idempotency-Key': 'issue'})
        token = issued.json()['token_payload'].split('/')[-1]
        gateway.set_room(ROOM, [gateway.member_event(ALICE, 'leave' if invalid_state == 'issuer_left' else 'join'), gateway.power_event({ALICE: 0 if invalid_state == 'issuer_demoted' else 100}), gateway.member_event(BOB, 'ban' if invalid_state == 'banned' else 'leave')])
        response = await client.post('/api/v1/groups/join-tokens/redeem', headers={**bearer(settings, 'u2'), 'Idempotency-Key': 'redeem'}, json={'token': token})
        assert response.status_code == 403
        assert gateway.invites == []
        assert gateway.joins == []


@pytest.mark.asyncio
@pytest.mark.parametrize('failure', ['join', 'ban', 'inactive'])
async def test_qr_approval_failure_rolls_back_and_can_retry(env, failure):
    from sqlalchemy import select
    from app.core.idempotency import IdempotencyRecord
    app, settings, gateway, factory = env
    events = [gateway.member_event(ALICE, 'join'), gateway.power_event({ALICE: 100}),
              {'type': 'com.changliao.group.settings', 'state_key': '', 'content': {'join_approval_required': True}}]
    gateway.set_room(ROOM, events)
    admin_headers = {**bearer(settings, 'u1'), 'Idempotency-Key': 'approval-retry'}
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        issued = await client.post(f'/api/v1/groups/{ROOM}/join-tokens', headers={**admin_headers, 'Idempotency-Key': 'issue'})
        token = issued.json()['token_payload'].split('/')[-1]
        await client.post('/api/v1/groups/join-tokens/redeem', headers={**bearer(settings, 'u2'), 'Idempotency-Key': 'request'}, json={'token': token})
        pending = await client.get(f'/api/v1/groups/{ROOM}/join-requests', headers=admin_headers)
        request_id = pending.json()['items'][0]['id']
        if failure == 'join':
            gateway.fail_join_for.add(BOB)
        elif failure == 'ban':
            gateway.set_room(ROOM, events + [gateway.member_event(BOB, 'ban')])
        else:
            with factory.begin() as session:
                session.get(User, 'u2').status = AccountStatus.PENDING_EMAIL
        response = await client.post(f'/api/v1/groups/join-requests/{request_id}/approve', headers=admin_headers)
        assert response.status_code == (502 if failure == 'join' else 403)
        with factory() as session:
            assert session.scalar(select(IdempotencyRecord).where(IdempotencyRecord.idempotency_key == 'approval-retry')) is None
        gateway.fail_join_for.clear()
        gateway.set_room(ROOM, events)
        with factory.begin() as session:
            session.get(User, 'u2').status = AccountStatus.ACTIVE
        approved = await client.post(f'/api/v1/groups/join-requests/{request_id}/approve', headers=admin_headers)
        assert approved.json() == {'status': 'approved'}
        replay = await client.post(f'/api/v1/groups/join-requests/{request_id}/approve', headers=admin_headers)
        assert replay.json() == approved.json()
        assert len(gateway.joins) == 1


def bearer(settings, user):
    now = datetime.now(timezone.utc)
    token = jwt.encode(
        {'sub': user, 'iss': settings.jwt_issuer, 'iat': int(now.timestamp()),
         'exp': int((now + timedelta(minutes=5)).timestamp())},
        settings.jwt_secret, algorithm='HS256')
    return {'Authorization': f'Bearer {token}'}


class FakeMatrixGateway:
    """内存 Synapse 替身：房间状态 + admin 代加入记录。"""

    def __init__(self):
        # rooms: {room_id: [state events]}
        self.rooms = {}
        self.joins = []  # (matrix_user_id, room_id, join_content)
        self.fail_join_for = set()
        self.invites = []

    def set_room(self, room_id, events):
        self.rooms[room_id] = events

    def member_event(self, user, membership, sender=None):
        return {
            'type': 'm.room.member', 'state_key': user, 'sender': sender or user,
            'content': {'membership': membership},
        }

    def power_event(self, users):
        return {'type': 'm.room.power_levels', 'state_key': '',
                'content': {'users': users, 'invite': 50}}

    def name_event(self, name):
        return {'type': 'm.room.name', 'state_key': '', 'content': {'name': name}}

    def get_room_state(self, room_id):
        return list(self.rooms.get(room_id, []))

    def join_room_as_user(self, matrix_user_id, room_id, *, join_content=None):
        membership = {e.get('state_key'): e.get('content', {}).get('membership')
                      for e in self.rooms.get(room_id, []) if e.get('type') == 'm.room.member'}
        if membership.get(matrix_user_id) not in ('invite', 'join'):
            from app.core.errors import AppError
            raise AppError(code='MATRIX_GROUP_JOIN_FAILED', message='Private room requires invite', status_code=502)
        if matrix_user_id in self.fail_join_for:
            from app.core.errors import AppError
            raise AppError(code='MATRIX_GROUP_JOIN_FAILED', message='群成员加入失败', status_code=502)
        self.joins.append((matrix_user_id, room_id, dict(join_content or {})))
        # 模拟 Matrix：join 后成员状态更新为 join。
        self.rooms.setdefault(room_id, [])
        self.rooms[room_id] = [
            e for e in self.rooms[room_id]
            if not (e.get('type') == 'm.room.member' and e.get('state_key') == matrix_user_id)
        ] + [self.member_event(matrix_user_id, 'join')]

    def invite_room_as_user(self, inviter_id, matrix_user_id, room_id):
        self.invites.append((inviter_id, matrix_user_id, room_id))
        self.rooms[room_id] = [e for e in self.rooms[room_id]
                               if not (e.get('type') == 'm.room.member' and e.get('state_key') == matrix_user_id)]
        self.rooms[room_id].append(self.member_event(matrix_user_id, 'invite', inviter_id))


@pytest.fixture
def env():
    engine = create_engine(
        'sqlite+pysqlite:///:memory:',
        connect_args={'check_same_thread': False}, poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        for user_id, name, mxid, auto_join in [
            ('u1', 'alice', ALICE, True),
            ('u2', 'bob', BOB, True),
            ('u3', 'carol', CAROL, False),
            ('u4', 'dave', DAVE, True),
        ]:
            session.add(User(
                id=user_id, username=name, username_normalized=name,
                email=f'{name}@x.test', email_normalized=f'{name}@x.test',
                password_hash='x', status=AccountStatus.ACTIVE, matrix_user_id=mxid,
                nickname=name.capitalize(), created_at=now, updated_at=now,
                auto_allow_group_join=auto_join,
            ))
        from app.modules.friendship.models import Friendship
        session.add(Friendship(id='f1', user_low_id='u1', user_high_id='u2', created_at=now))
        session.add(Friendship(id='f2', user_low_id='u1', user_high_id='u3', created_at=now))
        session.add(Friendship(id='f3', user_low_id='u1', user_high_id='u4', created_at=now))
    settings = Settings(_env_file=None, environment='test', jwt_secret='x' * 32)
    gateway = FakeMatrixGateway()
    app = create_app(settings, session_factory=factory, matrix_gateway=gateway)
    yield app, settings, gateway, factory


@pytest.mark.asyncio
async def test_auto_join_requires_operator_to_be_room_member(env):
    """操作者不在房间（如传他人 room_id）→ 403，绝不代加。"""
    app, settings, gateway, _ = env
    gateway.set_room(ROOM, [
        gateway.member_event(BOB, 'join'),
        gateway.member_event(CAROL, 'invite', sender=ALICE),
    ])
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        resp = await client.post('/api/v1/groups/auto-join', headers={
            **bearer(settings, 'u1'), 'Idempotency-Key': 'k1',
        }, json={'room_id': ROOM, 'invitee_user_ids': ['u3']})
    assert resp.status_code == 403
    assert resp.json()['error']['code'] == 'GROUP_OPERATOR_NOT_MEMBER'
    assert gateway.joins == []


@pytest.mark.asyncio
async def test_auto_join_requires_invite_from_operator(env):
    """被邀者没有该操作者发出的 invite（未真邀请）→ failed 分桶，不盲加。"""
    app, settings, gateway, _ = env
    gateway.set_room(ROOM, [
        gateway.member_event(ALICE, 'join'),
        # carol 的 invite 是别人发的，不是 alice：
        gateway.member_event(CAROL, 'invite', sender=DAVE),
    ])
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        resp = await client.post('/api/v1/groups/auto-join', headers={
            **bearer(settings, 'u1'), 'Idempotency-Key': 'k2',
        }, json={'room_id': ROOM, 'invitee_user_ids': ['u3']})
    assert resp.status_code == 200
    body = resp.json()
    assert body['joined_user_ids'] == []
    assert body['pending_user_ids'] == []
    assert body['failed'] == [{'user_id': 'u3', 'code': 'GROUP_INVITE_MISSING'}]
    assert gateway.joins == []


@pytest.mark.asyncio
async def test_auto_join_splits_by_preference_and_reports_partial_failure(env):
    """自动入群开→真加入；关→pending；Matrix 失败→failed（不伪装成功）。"""
    app, settings, gateway, _ = env
    gateway.set_room(ROOM, [
        gateway.member_event(ALICE, 'join'),
        gateway.member_event(BOB, 'invite', sender=ALICE),
        gateway.member_event(CAROL, 'invite', sender=ALICE),
        gateway.member_event(DAVE, 'invite', sender=ALICE),
    ])
    gateway.fail_join_for.add(BOB)  # bob 的 admin join 失败
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        resp = await client.post('/api/v1/groups/auto-join', headers={
            **bearer(settings, 'u1'), 'Idempotency-Key': 'k3',
        }, json={'room_id': ROOM, 'invitee_user_ids': ['u2', 'u3', 'u4']})
    assert resp.status_code == 200
    body = resp.json()
    assert body['joined_user_ids'] == ['u4']
    assert body['pending_user_ids'] == ['u3']
    codes = {entry['user_id']: entry['code'] for entry in body['failed']}
    assert codes == {'u2': 'MATRIX_GROUP_JOIN_FAILED'}
    # 只有 dave 被真正加入：
    assert [(user, room) for user, room, _ in gateway.joins] == [(DAVE, ROOM)]


@pytest.mark.asyncio
async def test_auto_join_is_idempotent_on_replay(env):
    app, settings, gateway, _ = env
    gateway.set_room(ROOM, [
        gateway.member_event(ALICE, 'join'),
        gateway.member_event(BOB, 'invite', sender=ALICE),
    ])
    headers = {**bearer(settings, 'u1'), 'Idempotency-Key': 'k4'}
    payload = {'room_id': ROOM, 'invitee_user_ids': ['u2']}
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        first = await client.post('/api/v1/groups/auto-join', headers=headers, json=payload)
        second = await client.post('/api/v1/groups/auto-join', headers=headers, json=payload)
    assert first.json()['joined_user_ids'] == ['u2']
    assert second.json().get('idempotent_replay') is True
    # 重放绝不重复代加：
    assert len(gateway.joins) == 1


@pytest.mark.asyncio
async def test_auto_join_rejects_non_friend_hard(env):
    """bob 在房间里邀请 carol（非 bob 好友）→ 整单 403。"""
    app, settings, gateway, _ = env
    gateway.set_room(ROOM, [
        gateway.member_event(BOB, 'join'),
        gateway.member_event(CAROL, 'invite', sender=BOB),
    ])
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        resp = await client.post('/api/v1/groups/auto-join', headers={
            **bearer(settings, 'u2'), 'Idempotency-Key': 'k5',
        }, json={'room_id': ROOM, 'invitee_user_ids': ['u3']})
    assert resp.status_code == 403
    assert resp.json()['error']['code'] == 'GROUP_INVITEE_NOT_FRIEND'


@pytest.mark.asyncio
async def test_join_token_lifecycle_issue_info_redeem_revoke(env):
    """签发→摘要（无 room_id）→兑换直加（带 qr 标记）→撤销后失效。"""
    app, settings, gateway, _ = env
    gateway.set_room(ROOM, [
        gateway.name_event('测试群'),
        gateway.member_event(ALICE, 'join'),
        gateway.power_event({ALICE: 100}),
    ])
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        issued = await client.post(f'/api/v1/groups/{ROOM}/join-tokens', headers={
            **bearer(settings, 'u1'), 'Idempotency-Key': 't1',
        })
        assert issued.status_code == 200
        payload = issued.json()['token_payload']
        assert payload.startswith('changliao://g/')
        token = payload.removeprefix('changliao://g/')

        info = await client.get('/api/v1/groups/join-info', params={'token': token}, headers=bearer(settings, 'u2'))
        assert info.status_code == 200
        body = info.json()
        assert body['group_name'] == '测试群'
        assert body['member_count'] == 1
        assert body['join_approval_required'] is False
        assert 'room_id' not in body  # 安全：不泄露房间

        redeem = await client.post('/api/v1/groups/join-tokens/redeem', headers={
            **bearer(settings, 'u2'), 'Idempotency-Key': 'r1',
        }, json={'token': token})
        assert redeem.status_code == 200
        assert redeem.json() == {'status': 'joined', 'room_id': ROOM}
        # qr 标记进入 join 内容（时间线推导扫码文案依据）：
        assert gateway.joins == [(BOB, ROOM, {'com.changliao.join_source': 'qr'})]

        # 已加入后重复兑换 → already_joined，不重复 join：
        again = await client.post('/api/v1/groups/join-tokens/redeem', headers={
            **bearer(settings, 'u2'), 'Idempotency-Key': 'r2',
        }, json={'token': token})
        assert again.json() == {'status': 'already_joined', 'room_id': ROOM}
        assert len(gateway.joins) == 1

        revoked = await client.post(f'/api/v1/groups/join-tokens/{token}/revoke', headers={
            **bearer(settings, 'u1'), 'Idempotency-Key': 'rv1',
        })
        assert revoked.status_code == 200
        after_revoke = await client.get('/api/v1/groups/join-info', params={'token': token}, headers=bearer(settings, 'u2'))
        assert after_revoke.status_code == 410
        assert after_revoke.json()['error']['code'] == 'GROUP_TOKEN_REVOKED'


@pytest.mark.asyncio
async def test_join_token_rejects_non_moderator_and_tampered_token(env):
    app, settings, gateway, _ = env
    gateway.set_room(ROOM, [
        gateway.member_event(ALICE, 'join'),
        gateway.member_event(BOB, 'join'),
        gateway.power_event({ALICE: 100}),  # bob 无管理权
    ])
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        forbidden = await client.post(f'/api/v1/groups/{ROOM}/join-tokens', headers={
            **bearer(settings, 'u2'), 'Idempotency-Key': 't2',
        })
        assert forbidden.status_code == 403
        assert forbidden.json()['error']['code'] == 'GROUP_OPERATOR_FORBIDDEN'

        tampered = await client.get(
            '/api/v1/groups/join-info',
            params={'token': 'totally-forged-token'},
            headers=bearer(settings, 'u2'),
        )
        assert tampered.status_code == 404
        assert tampered.json()['error']['code'] == 'GROUP_TOKEN_INVALID'


@pytest.mark.asyncio
async def test_redeem_routes_to_approval_when_required(env):
    """群开启审批 → 兑换转 pending；管理员批准后才真正加入。"""
    app, settings, gateway, _ = env
    gateway.set_room(ROOM, [
        gateway.name_event('审批群'),
        gateway.member_event(ALICE, 'join'),
        gateway.power_event({ALICE: 100}),
        {'type': 'com.changliao.group.settings', 'state_key': '',
         'content': {'qr_join_enabled': True, 'join_approval_required': True}},
    ])
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        issued = await client.post(f'/api/v1/groups/{ROOM}/join-tokens', headers={
            **bearer(settings, 'u1'), 'Idempotency-Key': 't3',
        })
        token = issued.json()['token_payload'].removeprefix('changliao://g/')

        redeem = await client.post('/api/v1/groups/join-tokens/redeem', headers={
            **bearer(settings, 'u2'), 'Idempotency-Key': 'r3',
        }, json={'token': token})
        assert redeem.json() == {'status': 'pending_approval', 'room_id': None}
        assert gateway.joins == []  # 未批准绝不加入（不能绕过审批）

        # 重复兑换同一 pending → 不重复建申请：
        again = await client.post('/api/v1/groups/join-tokens/redeem', headers={
            **bearer(settings, 'u2'), 'Idempotency-Key': 'r4',
        }, json={'token': token})
        assert again.json()['status'] == 'pending_approval'

        pending = await client.get(f'/api/v1/groups/{ROOM}/join-requests', headers=bearer(settings, 'u1'))
        items = pending.json()['items']
        assert len(items) == 1
        request_id = items[0]['id']

        # 普通成员不能批准：
        # dave 不在房间 → 403
        denied = await client.post(f'/api/v1/groups/join-requests/{request_id}/approve', headers={
            **bearer(settings, 'u4'), 'Idempotency-Key': 'ap1',
        })
        assert denied.status_code == 403

        approved = await client.post(f'/api/v1/groups/join-requests/{request_id}/approve', headers={
            **bearer(settings, 'u1'), 'Idempotency-Key': 'ap2',
        })
        assert approved.json() == {'status': 'approved'}
        assert [(user, room) for user, room, _ in gateway.joins] == [(BOB, ROOM)]


@pytest.mark.asyncio
async def test_disabled_qr_join_rejects_redeem(env):
    """群关闭二维码进群 → 签发仍可（可展示关闭态）但兑换/摘要被拒。"""
    app, settings, gateway, _ = env
    gateway.set_room(ROOM, [
        gateway.member_event(ALICE, 'join'),
        gateway.power_event({ALICE: 100}),
        {'type': 'com.changliao.group.settings', 'state_key': '',
         'content': {'qr_join_enabled': False}},
    ])
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        issued = await client.post(f'/api/v1/groups/{ROOM}/join-tokens', headers={
            **bearer(settings, 'u1'), 'Idempotency-Key': 't4',
        })
        token = issued.json()['token_payload'].removeprefix('changliao://g/')
        info = await client.get('/api/v1/groups/join-info', params={'token': token}, headers=bearer(settings, 'u2'))
        assert info.status_code == 410
        assert info.json()['error']['code'] == 'GROUP_TOKEN_DISABLED'
        redeem = await client.post('/api/v1/groups/join-tokens/redeem', headers={
            **bearer(settings, 'u2'), 'Idempotency-Key': 'r5',
        }, json={'token': token})
        assert redeem.status_code == 410
        assert gateway.joins == []


@pytest.mark.asyncio
async def test_expired_token_rejected(env):
    """过期令牌（默认 7 天）→ 410 GROUP_TOKEN_EXPIRED。"""
    app, settings, gateway, factory = env
    gateway.set_room(ROOM, [
        gateway.member_event(ALICE, 'join'),
        gateway.power_event({ALICE: 100}),
    ])
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        issued = await client.post(f'/api/v1/groups/{ROOM}/join-tokens', headers={
            **bearer(settings, 'u1'), 'Idempotency-Key': 't5',
        })
        token = issued.json()['token_payload'].removeprefix('changliao://g/')
    # 直接把数据库里的过期时间改到过去（模拟时间流逝）。
    from hashlib import sha256
    from app.modules.groups.models import GroupJoinToken
    with factory.begin() as session:
        from sqlalchemy import select
        record = session.scalar(
            select(GroupJoinToken).where(
                GroupJoinToken.token_hash == sha256(token.encode()).hexdigest()))
        record.expires_at = datetime.now(timezone.utc) - timedelta(minutes=1)
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        info = await client.get('/api/v1/groups/join-info', params={'token': token}, headers=bearer(settings, 'u2'))
        assert info.status_code == 410
        assert info.json()['error']['code'] == 'GROUP_TOKEN_EXPIRED'


@pytest.mark.asyncio
async def test_token_never_stored_in_plaintext(env):
    """数据库只存 sha256；令牌明文绝不落库。"""
    app, settings, gateway, factory = env
    gateway.set_room(ROOM, [
        gateway.member_event(ALICE, 'join'),
        gateway.power_event({ALICE: 100}),
    ])
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        issued = await client.post(f'/api/v1/groups/{ROOM}/join-tokens', headers={
            **bearer(settings, 'u1'), 'Idempotency-Key': 't6',
        })
        token = issued.json()['token_payload'].removeprefix('changliao://g/')
    from sqlalchemy import select
    from app.modules.groups.models import GroupJoinToken
    with factory() as session:
        rows = session.scalars(select(GroupJoinToken)).all()
        assert len(rows) == 1
        assert rows[0].token_hash != token
        assert len(rows[0].token_hash) == 64
        for row in rows:
            assert token not in (row.token_hash,)
