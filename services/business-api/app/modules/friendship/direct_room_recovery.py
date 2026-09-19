"""Replayable alias claims with Matrix metadata evidence and immutable publication."""
from datetime import datetime, timezone
from uuid import uuid4

from sqlalchemy import select

from app.core.errors import AppError
from app.modules.friendship.direct_room_coordinator import lock_pair
from app.modules.friendship.models import DirectConversation, DirectConversationRoom


V2_PREFIX = 'alias-v2:'


def alias_localpart(reservation):
    return 'chatflow_dm_' + reservation.id.replace('-', '')


class DirectRoomRecovery:
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
        low, high = sorted((actor, peer))
        with self.factory() as session:
            canonical = self._canonical(session, actor, peer)
            ids = set(session.scalars(select(DirectConversationRoom.matrix_room_id).where(
                DirectConversationRoom.user_low_id == low, DirectConversationRoom.user_high_id == high)))
            if canonical:
                ids.add(canonical.matrix_room_id)
            return {'matrix_room_id': canonical.matrix_room_id if canonical else None, 'room_ids': sorted(ids)}
