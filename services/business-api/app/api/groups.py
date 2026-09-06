"""群聊加入协调（服务端授权层；Matrix 仍是群成员关系的唯一权威）。

职责边界：
- /groups/auto-join：好友邀请成员的授权校验 + 代加入（读 Matrix 房间
  状态验证操作者与 invite 事实，绝不凭客户端 room_id 盲加）；
- 群二维码令牌：签发（随机 token，库存 sha256，默认 7 天）、撤销、
  安全摘要查询、兑换（直加或转审批）；
- 入群审批（群开启 join_approval_required 时）。

安全约束：所有写操作经 actor 鉴权 + Idempotency-Key 幂等 + AuditEvent
留痕；令牌明文只出现在签发响应中一次；不保存任何 Matrix 凭据或密钥。
"""
import json
from datetime import datetime, timedelta, timezone
from hashlib import sha256
from secrets import token_urlsafe
from typing import Annotated
from uuid import uuid4

from fastapi import APIRouter, Depends, Header
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select

from app.core.config import Settings
from app.core.errors import AppError
from app.core.idempotency import IdempotencyRecord
from app.modules.audit.writer import AuditWriter
from app.modules.friendship.models import Friendship
from app.modules.groups.models import GroupJoinRequest, GroupJoinToken
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User
from app.modules.identity.tokens import TokenService


class Strict(BaseModel):
    model_config = ConfigDict(extra='forbid')


class AutoJoinPreference(Strict):
    enabled: bool


class GroupAutoJoinRequest(Strict):
    room_id: str = Field(min_length=1, max_length=255)
    invitee_user_ids: list[str] = Field(min_length=1, max_length=499)


class GroupJoinRedeemRequest(Strict):
    token: str = Field(min_length=1, max_length=255)


# 群公开设置 state 事件（客户端写、服务端与全体成员可读）。
GROUP_SETTINGS_EVENT_TYPE = 'com.changliao.group.settings'
# 扫码加入标记（写入 join 的 m.room.member 内容，仅白名单键）。
QR_JOIN_SOURCE_CONTENT = {'com.changliao.join_source': 'qr'}
# 令牌默认有效期。
TOKEN_TTL = timedelta(days=7)


def _hash_token(token: str) -> str:
    return sha256(token.encode('utf-8')).hexdigest()


def _as_utc(value: datetime) -> datetime:
    """SQLite 测试库返回 naive datetime——统一归一为 UTC aware。"""
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value


def parse_room_membership(state_events: list[dict]) -> dict[str, dict]:
    """从房间状态提取成员事实：{matrix_user_id: {membership, sender}}。"""
    members: dict[str, dict] = {}
    for event in state_events:
        if event.get('type') != 'm.room.member':
            continue
        state_key = event.get('state_key')
        if not isinstance(state_key, str):
            continue
        content = event.get('content') or {}
        members[state_key] = {
            'membership': content.get('membership'),
            'sender': event.get('sender'),
        }
    return members


def parse_group_settings(state_events: list[dict]) -> dict:
    """群公开设置（qr_join_enabled 默认开、join_approval_required 默认关）。"""
    for event in state_events:
        if event.get('type') != GROUP_SETTINGS_EVENT_TYPE:
            continue
        content = event.get('content') or {}
        return {
            'qr_join_enabled': bool(content.get('qr_join_enabled', True)),
            'join_approval_required': bool(content.get('join_approval_required', False)),
        }
    return {'qr_join_enabled': True, 'join_approval_required': False}


def parse_room_summary(state_events: list[dict]) -> dict:
    """安全摘要：群名（m.room.name）与 join 成员数。"""
    name = ''
    joined = 0
    for event in state_events:
        etype = event.get('type')
        if etype == 'm.room.name':
            name = str((event.get('content') or {}).get('name') or '')
        elif etype == 'm.room.member':
            membership = (event.get('content') or {}).get('membership')
            if membership == 'join':
                joined += 1
    return {'group_name': name, 'member_count': joined}


def parse_power_levels(state_events: list[dict]) -> dict:
    for event in state_events:
        if event.get('type') == 'm.room.power_levels':
            content = event.get('content') or {}
            users = content.get('users') or {}
            return {
                'users': users if isinstance(users, dict) else {},
                'invite': content.get('invite', 0),
            }
    return {'users': {}, 'invite': 0}


def user_power(power_levels: dict, matrix_user_id: str | None) -> int:
    if not matrix_user_id:
        return 0
    value = (power_levels.get('users') or {}).get(matrix_user_id)
    return int(value) if isinstance(value, (int, float)) else 0


def moderator_power_requirement(power_levels: dict) -> int:
    """群管理动作（签发/撤销二维码、审批）要求 ≥50 或 invite 级（取高者）。"""
    return max(50, int(power_levels.get('invite', 0) or 0))


def create_group_router(settings: Settings, factory, *, matrix_gateway) -> APIRouter:
    router = APIRouter(tags=['groups'])
    tokens = TokenService(
        factory,
        jwt_secret=settings.jwt_secret or 'development-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer=settings.jwt_issuer,
        require_session_claims=settings.environment != 'test',
    )
    audit = AuditWriter(factory)

    def actor(authorization: Annotated[str | None, Header()] = None) -> str:
        if not authorization or not authorization.startswith('Bearer '):
            raise AppError(code='AUTH_REQUIRED', message='需要登录', status_code=401)
        return str(tokens.decode_access_token(authorization[7:])['sub'])

    def _idempotent_replay(session, scope: str, key: str, payload: dict) -> bool:
        """幂等键真实落库：同键同载荷=重放（跳过执行），同键异载荷=409。"""
        digest = sha256(
            json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()
        ).hexdigest()
        record = session.scalar(
            select(IdempotencyRecord).where(
                IdempotencyRecord.scope == scope,
                IdempotencyRecord.idempotency_key == key,
            )
        )
        if record:
            if record.request_hash != digest:
                raise AppError(code='IDEMPOTENCY_KEY_REUSED', message='幂等键已用于不同请求', status_code=409)
            return True
        now = datetime.now(timezone.utc)
        session.add(IdempotencyRecord(
            id=str(uuid4()), scope=scope, idempotency_key=key,
            request_hash=digest, status='COMPLETED', response_status=200,
            response_body={}, created_at=now, completed_at=now,
        ))
        return False

    def _operator(session, user_id: str) -> User:
        user = session.get(User, user_id)
        if user is None or user.status != AccountStatus.ACTIVE or not user.matrix_user_id:
            raise AppError(code='OPERATOR_UNAVAILABLE', message='操作者账号不可用', status_code=403)
        return user

    def _require_room_membership(state_events: list[dict], matrix_user_id: str, *, action: str) -> None:
        membership = parse_room_membership(state_events)
        if membership.get(matrix_user_id, {}).get('membership') != 'join':
            raise AppError(code='GROUP_OPERATOR_NOT_MEMBER', message=action, status_code=403)

    def _require_moderator(state_events: list[dict], matrix_user_id: str, *, action: str) -> None:
        _require_room_membership(state_events, matrix_user_id, action=action)
        power_levels = parse_power_levels(state_events)
        if user_power(power_levels, matrix_user_id) < moderator_power_requirement(power_levels):
            raise AppError(code='GROUP_OPERATOR_FORBIDDEN', message=action, status_code=403)

    @router.get('/profile/privacy')
    def get_privacy(user_id: str = Depends(actor)):
        with factory() as session:
            user = session.get(User, user_id)
            if user is None:
                raise AppError(code='USER_NOT_FOUND', message='账号不存在', status_code=404)
            return {'auto_allow_group_join': user.auto_allow_group_join}

    @router.put('/profile/privacy/auto-allow-group-join')
    def set_privacy(body: AutoJoinPreference, user_id: str = Depends(actor)):
        with factory.begin() as session:
            user = session.get(User, user_id)
            if user is None:
                raise AppError(code='USER_NOT_FOUND', message='账号不存在', status_code=404)
            user.auto_allow_group_join = body.enabled
            return {'auto_allow_group_join': user.auto_allow_group_join}

    @router.post('/groups/auto-join')
    def auto_join(
        body: GroupAutoJoinRequest,
        idempotency_key: Annotated[str, Header(alias='Idempotency-Key', min_length=1, max_length=128)],
        creator_id: str = Depends(actor),
    ):
        """好友邀请成员的授权代加入（建群与添加成员共用）。

        校验链：actor 身份 → 操作者在房间为 join → 每个被邀者存在
        sender=操作者的 invite 事件（Matrix 已对邀请鉴权的事实凭证）
        → 好友关系 → 目标账号可用 → auto_allow_group_join 分流。
        分桶返回：部分失败不中断其余成员，失败成员绝不伪装为已加入。
        """
        requested = list(dict.fromkeys(body.invitee_user_ids))
        with factory() as session:
            operator = _operator(session, creator_id)
            users = {
                user.id: user
                for user in session.scalars(
                    select(User).where(User.id.in_(requested))
                ).all()
            }
            friend_ids = set(
                session.scalars(
                    select(Friendship.user_high_id).where(Friendship.user_low_id == creator_id)
                ).all()
            ) | set(
                session.scalars(
                    select(Friendship.user_low_id).where(Friendship.user_high_id == creator_id)
                ).all()
            )
        with factory.begin() as session:
            replayed = _idempotent_replay(
                session,
                f'group.auto_join:{creator_id}',
                idempotency_key,
                {'room_id': body.room_id, 'invitee_user_ids': requested},
            )
        if replayed:
            return {
                'room_id': body.room_id,
                'joined_user_ids': [],
                'pending_user_ids': [],
                'failed': [],
                'idempotent_replay': True,
            }

        state_events = matrix_gateway.get_room_state(body.room_id)
        if not state_events:
            raise AppError(code='GROUP_ROOM_NOT_FOUND', message='群聊不存在', status_code=404)
        _require_room_membership(
            state_events, operator.matrix_user_id, action='只有群成员才能添加成员',
        )
        membership = parse_room_membership(state_events)

        eligible: list[User] = []
        pending: list[User] = []
        failed: list[dict] = []
        for invitee_id in requested:
            user = users.get(invitee_id)
            if invitee_id not in friend_ids:
                # 非好友是安全硬边界：整单 403。
                raise AppError(code='GROUP_INVITEE_NOT_FRIEND', message='只能邀请好友加入群聊', status_code=403)
            if user is None or user.status != AccountStatus.ACTIVE or not user.matrix_user_id:
                failed.append({'user_id': invitee_id, 'code': 'GROUP_INVITEE_UNAVAILABLE'})
                continue
            invitee_state = membership.get(user.matrix_user_id, {})
            if invitee_state.get('membership') == 'join':
                # 已在群：幂等成功（不重复 join、不重复通知）。
                failed.append({'user_id': invitee_id, 'code': 'GROUP_INVITEE_ALREADY_JOINED'})
                continue
            if (
                invitee_state.get('membership') != 'invite'
                or invitee_state.get('sender') != operator.matrix_user_id
            ):
                # 必须存在操作者发出的 invite——证明 Matrix 已对邀请权
                # 限完成鉴权（客户端 room.invite() 先行），服务端不越权代加。
                failed.append({'user_id': invitee_id, 'code': 'GROUP_INVITE_MISSING'})
                continue
            (eligible if user.auto_allow_group_join else pending).append(user)

        joined: list[str] = []
        for user in eligible:
            try:
                matrix_gateway.join_room_as_user(user.matrix_user_id, body.room_id)
                joined.append(user.id)
            except AppError:
                failed.append({'user_id': user.id, 'code': 'MATRIX_GROUP_JOIN_FAILED'})
        audit.record(
            actor_id=creator_id, subject_type='group', subject_id=body.room_id,
            action='group.auto_join',
            result='ok' if not failed else 'partial',
            reason_code='GROUP_AUTO_JOIN', trace_id=idempotency_key,
            after={'joined': len(joined), 'pending': len(pending), 'failed': len(failed)},
        )
        return {
            'room_id': body.room_id,
            'joined_user_ids': joined,
            'pending_user_ids': [user.id for user in pending],
            'failed': failed,
        }

    # ── 群二维码令牌 ────────────────────────────────────────────────

    def _qr_begin(session, actor_id, scope, key, payload):
        # Serialize this actor's QR writes, including different keys. NO KEY
        # UPDATE permits FK checks while preventing duplicate concurrent work.
        session.scalar(select(User).where(User.id == actor_id).with_for_update(key_share=True))
        digest = sha256(json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        row = session.scalar(select(IdempotencyRecord).where(
            IdempotencyRecord.scope == scope,
            IdempotencyRecord.idempotency_key == key,
        ))
        if row is not None:
            if row.request_hash != digest:
                raise AppError(code='IDEMPOTENCY_KEY_REUSED', message='幂等键已用于不同请求', status_code=409)
            if not row.response_body:
                raise AppError(code='GROUP_TOKEN_ALREADY_ISSUED', message='该请求已处理，请使用新的请求重新生成二维码', status_code=409)
            return row, True
        row = IdempotencyRecord(
            id=str(uuid4()), scope=scope, idempotency_key=key, request_hash=digest,
            status='IN_PROGRESS', created_at=datetime.now(timezone.utc),
        )
        session.add(row)
        return row, False

    def _qr_complete(row, response, *, secret=False):
        row.status = 'COMPLETED'
        row.response_status = 200
        row.response_body = {} if secret else response
        row.completed_at = datetime.now(timezone.utc)
        return response

    def _qr_invite(session, state_events, inviter_id, requester, room_id):
        inviter = _operator(session, inviter_id)
        _require_moderator(state_events, inviter.matrix_user_id, action='二维码签发者已无邀请权限，请管理员刷新二维码')
        membership = parse_room_membership(state_events).get(requester.matrix_user_id, {}).get('membership')
        if membership == 'ban':
            raise AppError(code='GROUP_INVITEE_BANNED', message='该账号已被群聊封禁', status_code=403)
        if membership not in ('invite', 'join'):
            matrix_gateway.invite_room_as_user(inviter.matrix_user_id, requester.matrix_user_id, room_id)

    @router.post('/groups/{room_id}/join-tokens')
    def issue_join_token(
        room_id: str,
        idempotency_key: Annotated[str, Header(alias='Idempotency-Key', min_length=1, max_length=128)],
        actor_user_id: str = Depends(actor),
    ):
        """签发群二维码令牌（群主/管理员）。"""
        with factory.begin() as session:
            operator = _operator(session, actor_user_id)
            operation, _ = _qr_begin(
                session, actor_user_id, f'group.token.issue:{actor_user_id}', idempotency_key,
                {'room_id': room_id},
            )
            state_events = matrix_gateway.get_room_state(room_id)
            if not state_events:
                raise AppError(code='GROUP_ROOM_NOT_FOUND', message='群聊不存在', status_code=404)
            _require_moderator(
                state_events, operator.matrix_user_id, action='只有群主或管理员才能生成群二维码',
            )

            token = token_urlsafe(32)
            now = datetime.now(timezone.utc)
            record = GroupJoinToken(
                id=str(uuid4()), room_id=room_id, creator_user_id=actor_user_id,
                token_hash=_hash_token(token), created_at=now,
                expires_at=now + TOKEN_TTL, revoked_at=None,
            )
            session.add(record)
            audit.record_in_session(session,
                actor_id=actor_user_id, subject_type='group_join_token',
                subject_id=record.id, action='group.token.issue', result='ok',
                reason_code='GROUP_TOKEN_ISSUED', trace_id=idempotency_key,
                after={'room_id': room_id, 'expires_at': record.expires_at.isoformat()},
            )
            return _qr_complete(operation, {
                'token_payload': f'changliao://g/{token}',
                'expires_at': record.expires_at.isoformat(),
            }, secret=True)

    def _load_valid_token(token: str, session=None) -> GroupJoinToken:
        """按哈希定位并校验令牌（无效/撤销/过期 → 明确错误码）。"""
        if session is None:
            with factory() as owned_session:
                return _load_valid_token(token, owned_session)
        else:
            record = session.scalar(
                    select(GroupJoinToken).where(GroupJoinToken.token_hash == _hash_token(token)).with_for_update()
            )
            if record is None:
                raise AppError(code='GROUP_TOKEN_INVALID', message='二维码无效', status_code=404)
            current = datetime.now(timezone.utc)
            if record.revoked_at is not None:
                raise AppError(code='GROUP_TOKEN_REVOKED', message='二维码已被撤销', status_code=410)
            if _as_utc(record.expires_at) <= current:
                raise AppError(code='GROUP_TOKEN_EXPIRED', message='二维码已过期', status_code=410)
            return record

    @router.get('/groups/join-info')
    def join_info(token: str, user_id: str = Depends(actor)):
        """扫码后的安全摘要（不返回 room_id 与令牌明文）。"""
        record = _load_valid_token(token)
        state_events = matrix_gateway.get_room_state(record.room_id)
        if not state_events:
            raise AppError(code='GROUP_ROOM_NOT_FOUND', message='群聊不存在', status_code=410)
        group_settings = parse_group_settings(state_events)
        if not group_settings['qr_join_enabled']:
            raise AppError(code='GROUP_TOKEN_DISABLED', message='该群已关闭二维码进群', status_code=410)
        summary = parse_room_summary(state_events)
        return {
            'group_name': summary['group_name'],
            'member_count': summary['member_count'],
            'join_approval_required': group_settings['join_approval_required'],
            'expires_at': record.expires_at.isoformat(),
        }

    @router.post('/groups/join-tokens/redeem')
    def redeem_join_token(
        body: GroupJoinRedeemRequest,
        idempotency_key: Annotated[str, Header(alias='Idempotency-Key', min_length=1, max_length=128)],
        actor_user_id: str = Depends(actor),
    ):
        """扫码入群：校验令牌与群设置 → 直加或转审批。"""
        with factory.begin() as session:
            requester = _operator(session, actor_user_id)
            operation, replayed = _qr_begin(
                session, actor_user_id, f'group.token.redeem:{actor_user_id}', idempotency_key,
                {'token': _hash_token(body.token)},
            )
            if replayed:
                return operation.response_body

            record = _load_valid_token(body.token, session)
            room_id = record.room_id
            state_events = matrix_gateway.get_room_state(room_id)
            if not state_events:
                raise AppError(code='GROUP_ROOM_NOT_FOUND', message='群聊不存在', status_code=410)
            group_settings = parse_group_settings(state_events)
            if not group_settings['qr_join_enabled']:
                raise AppError(code='GROUP_TOKEN_DISABLED', message='该群已关闭二维码进群', status_code=410)
            membership = parse_room_membership(state_events)
            if membership.get(requester.matrix_user_id, {}).get('membership') == 'join':
                return _qr_complete(operation, {'status': 'already_joined', 'room_id': room_id})
            if membership.get(requester.matrix_user_id, {}).get('membership') == 'ban':
                raise AppError(code='GROUP_INVITEE_BANNED', message='该账号已被群聊封禁', status_code=403)

            if group_settings['join_approval_required']:
                now = datetime.now(timezone.utc)
                existing = session.scalar(
                    select(GroupJoinRequest).where(
                        GroupJoinRequest.room_id == room_id,
                        GroupJoinRequest.requester_user_id == actor_user_id,
                        GroupJoinRequest.status == 'PENDING',
                    )
                )
                if existing is None:
                    session.add(GroupJoinRequest(
                        id=str(uuid4()), room_id=room_id,
                        requester_user_id=actor_user_id, token_id=record.id,
                        status='PENDING', created_at=now,
                    ))
                audit.record_in_session(session,
                    actor_id=actor_user_id, subject_type='group', subject_id=room_id,
                    action='group.join_request.submit', result='ok',
                    reason_code='GROUP_JOIN_REQUEST_PENDING', trace_id=idempotency_key,
                )
                return _qr_complete(operation, {'status': 'pending_approval', 'room_id': None})

            _qr_invite(session, state_events, record.creator_user_id, requester, room_id)
            matrix_gateway.join_room_as_user(
                requester.matrix_user_id, room_id,
                join_content=dict(QR_JOIN_SOURCE_CONTENT),
            )
            audit.record_in_session(session,
                actor_id=actor_user_id, subject_type='group', subject_id=room_id,
                action='group.join_qr', result='ok', reason_code='GROUP_QR_JOINED',
                trace_id=idempotency_key,
            )
            return _qr_complete(operation, {'status': 'joined', 'room_id': room_id})

    @router.post('/groups/join-tokens/{token}/revoke')
    def revoke_join_token(
        token: str,
        idempotency_key: Annotated[str, Header(alias='Idempotency-Key', min_length=1, max_length=128)],
        actor_user_id: str = Depends(actor),
    ):
        """撤销令牌（轮换=再签发新令牌后撤销旧令牌）。"""
        with factory.begin() as session:
            operator = _operator(session, actor_user_id)
            operation, replayed = _qr_begin(
                session, actor_user_id, f'group.token.revoke:{actor_user_id}', idempotency_key,
                {'token': _hash_token(token)},
            )
            if replayed:
                return operation.response_body
            record = session.scalar(
                select(GroupJoinToken).where(GroupJoinToken.token_hash == _hash_token(token)).with_for_update()
            )
            if record is None:
                raise AppError(code='GROUP_TOKEN_INVALID', message='二维码无效', status_code=404)
            # Record stays in this transaction.
            state_events = matrix_gateway.get_room_state(record.room_id)
            if not state_events:
                raise AppError(code='GROUP_ROOM_NOT_FOUND', message='群聊不存在', status_code=404)
            _require_moderator(
                state_events, operator.matrix_user_id, action='只有群主或管理员才能管理群二维码',
            )
            fresh = session.get(GroupJoinToken, record.id)
            if fresh is not None and fresh.revoked_at is None:
                fresh.revoked_at = datetime.now(timezone.utc)
            audit.record_in_session(session,
                actor_id=actor_user_id, subject_type='group_join_token',
                subject_id=record.id, action='group.token.revoke', result='ok',
                reason_code='GROUP_TOKEN_REVOKED', trace_id=idempotency_key,
            )
            return _qr_complete(operation, {'revoked': True})

    # ── 入群审批 ────────────────────────────────────────────────────

    @router.get('/groups/{room_id}/join-requests')
    def list_join_requests(room_id: str, actor_user_id: str = Depends(actor)):
        with factory() as session:
            operator = _operator(session, actor_user_id)
        state_events = matrix_gateway.get_room_state(room_id)
        if not state_events:
            raise AppError(code='GROUP_ROOM_NOT_FOUND', message='群聊不存在', status_code=404)
        _require_moderator(
            state_events, operator.matrix_user_id, action='只有群主或管理员才能查看入群申请',
        )
        with factory() as session:
            rows = session.scalars(
                select(GroupJoinRequest).where(
                    GroupJoinRequest.room_id == room_id,
                    GroupJoinRequest.status == 'PENDING',
                ).order_by(GroupJoinRequest.created_at)
            ).all()
            requester_ids = [row.requester_user_id for row in rows]
            profiles = {
                user.id: user
                for user in session.scalars(
                    select(User).where(User.id.in_(requester_ids))
                ).all()
            }
        return {
            'items': [
                {
                    'id': row.id,
                    'requester_user_id': row.requester_user_id,
                    'requester_nickname': (getattr(profiles.get(row.requester_user_id), 'nickname', '') or ''),
                    'created_at': row.created_at.isoformat(),
                }
                for row in rows
            ]
        }

    @router.post('/groups/join-requests/{request_id}/approve')
    def approve_join_request(
        request_id: str,
        idempotency_key: Annotated[str, Header(alias='Idempotency-Key', min_length=1, max_length=128)],
        actor_user_id: str = Depends(actor),
    ):
        return _decide_join_request(request_id, actor_user_id, idempotency_key, approved=True)

    @router.post('/groups/join-requests/{request_id}/reject')
    def reject_join_request(
        request_id: str,
        idempotency_key: Annotated[str, Header(alias='Idempotency-Key', min_length=1, max_length=128)],
        actor_user_id: str = Depends(actor),
    ):
        return _decide_join_request(request_id, actor_user_id, idempotency_key, approved=False)

    def _decide_join_request(
        request_id: str, actor_user_id: str, idempotency_key: str, *, approved: bool,
    ) -> dict:
        with factory.begin() as session:
            operator = _operator(session, actor_user_id)
            operation, replayed = _qr_begin(
                session, actor_user_id, f'group.join_request.decide:{actor_user_id}', idempotency_key,
                {'request_id': request_id, 'approved': approved},
            )
            if replayed:
                return operation.response_body
            record = session.scalar(select(GroupJoinRequest).where(GroupJoinRequest.id == request_id).with_for_update())
            if record is None:
                raise AppError(code='GROUP_JOIN_REQUEST_NOT_FOUND', message='入群申请不存在', status_code=404)
            room_id = record.room_id
            requester_id = record.requester_user_id
            # Record stays in this transaction.
            state_events = matrix_gateway.get_room_state(room_id)
            if not state_events:
                raise AppError(code='GROUP_ROOM_NOT_FOUND', message='群聊不存在', status_code=404)
            _require_moderator(
                state_events, operator.matrix_user_id, action='只有群主或管理员才能处理入群申请',
            )
            if record.status != 'PENDING':
                return _qr_complete(operation, {'status': record.status.lower()})

            if approved:
                requester = _operator(session, requester_id)
                _qr_invite(session, state_events, actor_user_id, requester, room_id)
                matrix_gateway.join_room_as_user(requester.matrix_user_id, room_id, join_content=dict(QR_JOIN_SOURCE_CONTENT))
            now = datetime.now(timezone.utc)
            fresh = session.get(GroupJoinRequest, request_id)
            if fresh is not None and fresh.status == 'PENDING':
                fresh.status = 'APPROVED' if approved else 'REJECTED'
                fresh.decided_at = now
                fresh.decider_user_id = actor_user_id
            audit.record_in_session(session,
                actor_id=actor_user_id, subject_type='group', subject_id=room_id,
                action='group.join_request.decide', result='ok',
                reason_code='APPROVED' if approved else 'REJECTED',
                trace_id=idempotency_key, after={'request_id': request_id},
            )
            return _qr_complete(operation, {'status': 'approved' if approved else 'rejected'})

    return router
