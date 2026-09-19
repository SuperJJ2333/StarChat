"""Replayable alias claims with Matrix metadata evidence and immutable publication."""
from datetime import datetime, timezone
from hashlib import sha256
import json
from uuid import uuid4

from sqlalchemy import and_, or_, select

from app.core.errors import AppError
from app.core.idempotency import IdempotencyRecord
from app.core.outbox import OutboxPublisher
from app.modules.audit.models import AuditEvent
from app.modules.friendship.direct_room_coordinator import lock_pair
from app.modules.friendship.models import DirectConversation, DirectConversationRoom, Friendship, UserBlock


V2_PREFIX = 'alias-v2:'


def alias_localpart(reservation):
    return 'chatflow_dm_' + reservation.id.replace('-', '')


class DirectRoomRecovery:
    def repair_retired_direct_conversation(self, *, operator_id, actor, peer,
                                           expected_old_room_id, target_room_id,
                                           idempotency_key):
        """Explicit operations-only correction; deliberately has no HTTP route.

        The caller supplies its authenticated operational identity. Ordinary
        client publication remains immutable; no Matrix membership is changed.
        """
        if (not isinstance(operator_id, str) or not operator_id.strip() or len(operator_id) > 36
                or not isinstance(idempotency_key, str) or not idempotency_key.strip() or len(idempotency_key) > 128
                or not all(isinstance(value, str) and value for value in (actor, peer))
                or actor == peer or expected_old_room_id == target_room_id
                or not all(isinstance(value, str) and value.startswith('!') and len(value) <= 255
                           for value in (expected_old_room_id, target_room_id))):
            raise AppError(code='DIRECT_ROOM_REPAIR_INVALID', message='会话修复参数无效', status_code=422)
        low, high = sorted((actor, peer))
        reason = 'DIRECT_ROOM_RETIRED_REPAIR'
        scope = 'friend.direct.retired.repair'
        payload = dict(operator_id=operator_id, user_low_id=low, user_high_id=high,
                       expected_old_room_id=expected_old_room_id, target_room_id=target_room_id,
                       reason_code=reason)
        digest = sha256(json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        with self.factory.begin() as session:
            # Existing reservation owner/attempt/alias are never altered.
            lock_pair(session, actor, peer, V2_PREFIX + 'operations-repair')
            record = session.scalar(select(IdempotencyRecord).where(
                IdempotencyRecord.scope == scope, IdempotencyRecord.idempotency_key == idempotency_key))
            if record is not None:
                if record.request_hash != digest:
                    raise AppError(code='IDEMPOTENCY_KEY_REUSED', message='幂等键已用于不同请求', status_code=409)
                if record.status != 'COMPLETED' or record.response_status != 200 or not isinstance(record.response_body, dict):
                    raise AppError(code='DIRECT_ROOM_REPAIR_CONFLICT', message='会话修复记录未完成', status_code=409)
                original = self._canonical(session, actor, peer)
                if original is None or record.response_body != dict(
                        conversation_id=original.id, matrix_room_id=target_room_id,
                        previous_room_id=expected_old_room_id):
                    raise AppError(code='DIRECT_ROOM_REPAIR_CONFLICT', message='会话修复记录不匹配', status_code=409)
                return record.response_body
            canonical = self._canonical(session, actor, peer)
            if canonical is None or canonical.matrix_room_id != expected_old_room_id:
                raise AppError(code='DIRECT_ROOM_REPAIR_CONFLICT', message='规范会话已变化', status_code=409)
            friendship = session.scalar(select(Friendship).where(
                Friendship.user_low_id == low, Friendship.user_high_id == high).with_for_update())
            blocked = session.scalar(select(UserBlock.id).where(or_(
                and_(UserBlock.blocker_id == actor, UserBlock.blocked_id == peer),
                and_(UserBlock.blocker_id == peer, UserBlock.blocked_id == actor))))
            if friendship is None or blocked is not None:
                raise AppError(code='DIRECT_ROOM_REPAIR_FORBIDDEN', message='好友关系不允许修复', status_code=409)
            associated = session.scalar(select(DirectConversationRoom.id).where(
                DirectConversationRoom.user_low_id == low, DirectConversationRoom.user_high_id == high,
                DirectConversationRoom.matrix_room_id == target_room_id))
            if associated is None:
                raise AppError(code='DIRECT_ROOM_REPAIR_FORBIDDEN', message='目标不是已登记历史会话', status_code=409)
            # Fresh metadata is deliberately fetched while holding the pair lock.
            self._verify_retired_repair_evidence(actor, peer, expected_old_room_id, target_room_id)
            # Blocking is a separate business write, not serialized by the pair
            # reservation. Re-read after potentially slow Matrix metadata I/O.
            blocked = session.scalar(select(UserBlock.id).where(or_(
                and_(UserBlock.blocker_id == actor, UserBlock.blocked_id == peer),
                and_(UserBlock.blocker_id == peer, UserBlock.blocked_id == actor))))
            if blocked is not None:
                raise AppError(code='DIRECT_ROOM_REPAIR_FORBIDDEN', message='好友关系不允许修复', status_code=409)
            old_source = session.scalar(select(DirectConversationRoom.id).where(
                DirectConversationRoom.user_low_id == low, DirectConversationRoom.user_high_id == high,
                DirectConversationRoom.matrix_room_id == expected_old_room_id))
            now = datetime.now(timezone.utc)
            if old_source is None:
                session.add(DirectConversationRoom(id=str(uuid4()), user_low_id=low, user_high_id=high,
                    matrix_room_id=expected_old_room_id, created_at=now))
            before = dict(matrix_room_id=expected_old_room_id, user_low_id=low, user_high_id=high)
            after = dict(matrix_room_id=target_room_id, user_low_id=low, user_high_id=high)
            canonical.matrix_room_id = target_room_id
            canonical.revision += 1
            result = dict(conversation_id=canonical.id, matrix_room_id=target_room_id, previous_room_id=expected_old_room_id)
            session.add(AuditEvent(id=str(uuid4()), actor_id=operator_id, subject_type='friendship',
                subject_id=canonical.id, action='friend.direct_room_repaired', result='SUCCESS',
                reason_code=reason, trace_id=idempotency_key, before_data=before, after_data=after, created_at=now))
            OutboxPublisher.enqueue(session, topic='friendship.events', event_type='friend.direct_room_repaired',
                aggregate_type='friendship', aggregate_id=canonical.id,
                payload=dict(operator_id=operator_id, before=before, after=after,
                             reason_code=reason, idempotency_key=idempotency_key))
            session.add(IdempotencyRecord(id=str(uuid4()), scope=scope, idempotency_key=idempotency_key,
                request_hash=digest, status='COMPLETED', response_status=200, response_body=result,
                created_at=now, completed_at=now))
            return result

    def _verify_retired_repair_evidence(self, actor, peer, old_room, target_room):
        gateway = self.matrix_gateway
        if gateway is None:
            raise AppError(code='DIRECT_ROOM_EVIDENCE_UNAVAILABLE', message='会话校验暂不可用', status_code=503)
        def invalid():
            raise AppError(code='DIRECT_ROOM_INVALID_EVIDENCE', message='房间退休或成员证据不匹配', status_code=409)
        profiles = self.profile_reader.read_public_profiles([actor, peer])
        expected = {getattr(profiles.get(user), 'matrix_user_id', None) for user in (actor, peer)}
        if len(expected) != 2 or not all(isinstance(user, str) and user.startswith('@') for user in expected):
            invalid()
        def indexed(room):
            events = gateway.get_room_state_strict(room)
            if not isinstance(events, list):
                invalid()
            result = {}
            for event in events:
                if (not isinstance(event, dict) or not isinstance(event.get('type'), str)
                        or not isinstance(event.get('state_key'), str) or not isinstance(event.get('content'), dict)):
                    invalid()
                key = event['type'], event['state_key']
                if key in result:
                    invalid()
                result[key] = event['content']
                if key[0] == 'm.room.member':
                    membership = event['content'].get('membership')
                    if not isinstance(membership, str) or membership not in {'join', 'invite', 'knock', 'ban', 'leave'}:
                        invalid()
            return result
        target = indexed(target_room)
        members = {key: content['membership'] for (kind, key), content in target.items() if kind == 'm.room.member'}
        if (set(key for key, membership in members.items() if membership != 'leave') != expected
                or any(members.get(user) != 'join' for user in expected)
                or target.get(('m.room.encryption', ''), {}).get('algorithm') != 'm.megolm.v1.aes-sha2'):
            invalid()
        details = gateway.get_room_details(old_room)
        if (not isinstance(details, dict) or details.get('room_id') != old_room
                or type(details.get('joined_members')) is not int or details['joined_members'] != 0):
            invalid()
        old = indexed(old_room)
        if any(content['membership'] != 'leave' for (kind, _), content in old.items() if kind == 'm.room.member'):
            invalid()

    def _canonical(self, session, actor, peer):
        low, high = sorted((actor, peer))
        return session.scalar(select(DirectConversation).where(
            DirectConversation.user_low_id == low, DirectConversation.user_high_id == high))

    def claim_direct_conversation_v2(self, actor, peer, attempt_id):
        self._validate_direct_peer(actor, peer)
        if self.matrix_gateway is None:
            raise AppError(code='DIRECT_ROOM_EVIDENCE_UNAVAILABLE', message='会话校验暂不可用', status_code=503)
        with self.factory.begin() as session:
            reservation, inserted = lock_pair(session, actor, peer, V2_PREFIX + attempt_id)
            canonical = self._canonical(session, actor, peer)
            if canonical is None and (inserted or not reservation.attempt_id.startswith(V2_PREFIX)):
                # This fences old *publication*, not Matrix requests already in flight.
                # Physical rooms remain readable history; only this alias can publish.
                reservation.attempt_id = V2_PREFIX + attempt_id
                self._audit(session, actor, reservation.id, 'friend.direct_room_recoverable', 'DIRECT_ROOM_V2_CLAIM', attempt_id)
            return {'matrix_room_id': canonical.matrix_room_id if canonical else None,
                    'may_create': canonical is None, 'can_publish': canonical is None,
                    'room_alias_localpart': alias_localpart(reservation), 'reservation_id': reservation.id}

    def _verify_direct_room(self, actor, peer, room_id):
        if self.matrix_gateway is None:
            raise AppError(code='DIRECT_ROOM_EVIDENCE_UNAVAILABLE', message='会话校验暂不可用', status_code=503)
        profiles = self.profile_reader.read_public_profiles([actor, peer])
        expected = {getattr(profiles.get(user), 'matrix_user_id', None) for user in (actor, peer)}
        if None in expected or len(expected) != 2:
            raise AppError(code='DIRECT_ROOM_INVALID_EVIDENCE', message='会话身份尚未就绪', status_code=409)
        state = self.matrix_gateway.get_room_state(room_id)
        indexed = {(e.get('type'), e.get('state_key')): e.get('content', {}) for e in state}
        active = {key for (kind, key), content in indexed.items()
                  if kind == 'm.room.member' and content.get('membership') in {'join', 'invite'}}
        encrypted = indexed.get(('m.room.encryption', ''), {}).get('algorithm') == 'm.megolm.v1.aes-sha2'
        if active != expected or not encrypted:
            raise AppError(code='DIRECT_ROOM_INVALID_EVIDENCE', message='房间成员或加密状态不匹配', status_code=409)
        return indexed

    def _remember_direct_room(self, session, actor, peer, room_id, key):
        low, high = sorted((actor, peer))
        existing = session.scalar(select(DirectConversationRoom).where(
            DirectConversationRoom.user_low_id == low, DirectConversationRoom.user_high_id == high,
            DirectConversationRoom.matrix_room_id == room_id))
        if existing is None:
            row = DirectConversationRoom(id=str(uuid4()), user_low_id=low, user_high_id=high,
                                         matrix_room_id=room_id, created_at=datetime.now(timezone.utc))
            session.add(row)
            self._audit(session, actor, row.id, 'friend.direct_room_associated', 'DIRECT_ROOM_ASSOCIATE', key)

    def recover_direct_conversation(self, actor, peer, attempt_id, matrix_room_id):
        self._validate_direct_peer(actor, peer)
        evidence = self._verify_direct_room(actor, peer, matrix_room_id)
        with self.factory.begin() as session:
            reservation, inserted = lock_pair(session, actor, peer, attempt_id)
            if inserted:
                raise AppError(code='DIRECT_ROOM_NOT_OWNER', message='请先预约会话', status_code=409)
            canonical = self._canonical(session, actor, peer)
            if canonical is None and reservation.attempt_id.startswith(V2_PREFIX):
                alias = f'#{alias_localpart(reservation)}:{self.matrix_server_name}'
                marker = evidence.get(('com.chatflow.direct_reservation', ''), {}).get('reservation_id')
                if marker != reservation.id or self.matrix_gateway.resolve_room_alias(alias) != matrix_room_id:
                    raise AppError(code='DIRECT_ROOM_INVALID_EVIDENCE', message='房间预约证据不匹配', status_code=409)
            self._remember_direct_room(session, actor, peer, matrix_room_id, attempt_id)
            if canonical is None:
                low, high = sorted((actor, peer))
                canonical = DirectConversation(id=str(uuid4()), user_low_id=low, user_high_id=high,
                                               matrix_room_id=matrix_room_id, created_at=datetime.now(timezone.utc))
                session.add(canonical)
                self._audit(session, actor, canonical.id, 'friend.direct_room_recovered', 'DIRECT_ROOM_RECOVER', attempt_id)
            return {'matrix_room_id': canonical.matrix_room_id}

    def associate_direct_conversation(self, actor, peer, matrix_room_id):
        self._validate_direct_peer(actor, peer)
        self._verify_direct_room(actor, peer, matrix_room_id)
        with self.factory.begin() as session:
            lock_pair(session, actor, peer, 'history:' + str(uuid4()))
            self._remember_direct_room(session, actor, peer, matrix_room_id, str(uuid4()))
        return self.direct_conversation_associations(actor, peer)

    def direct_conversation_associations(self, actor, peer):
        self._validate_direct_peer(actor, peer)
        self.reconcile_direct_directory(actor, peer)
        low, high = sorted((actor, peer))
        with self.factory() as session:
            canonical = self._canonical(session, actor, peer)
            ids = set(session.scalars(select(DirectConversationRoom.matrix_room_id).where(
                DirectConversationRoom.user_low_id == low, DirectConversationRoom.user_high_id == high)))
            if canonical:
                ids.add(canonical.matrix_room_id)
            return {'matrix_room_id': canonical.matrix_room_id if canonical else None, 'room_ids': sorted(ids),
                    'revision': canonical.revision if canonical else 0}
