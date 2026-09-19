"""Authoritative destination recovery. Matrix metadata only; never user keys."""
from collections import OrderedDict
from contextlib import contextmanager
from datetime import datetime, timezone
from hashlib import sha256
from threading import BoundedSemaphore, Lock
from time import monotonic
from uuid import uuid4

from sqlalchemy import and_, or_, select, text
from sqlalchemy.exc import OperationalError

from app.core.errors import AppError
from app.core.outbox import OutboxPublisher
from app.modules.audit.models import AuditEvent
from app.modules.friendship.direct_room_coordinator import lock_pair
from app.modules.friendship.direct_room_recovery import V2_PREFIX, alias_localpart
from app.modules.friendship.models import DirectConversation, DirectConversationRoom, DirectRoomGeneration, Friendship, UserBlock
from app.modules.identity.models import User
from app.modules.identity.enums import AccountStatus

# Per-process admission (not a distributed lease): four metadata probes maximum.
# The DB pair lock fences writes across workers. Cache is never evidence.
_slots = BoundedSemaphore(4)
_cache_lock = Lock()
_checks = OrderedDict()
_scan_cursors = OrderedDict()
SCAN_CACHE_LIMIT = 4096
PROBE_SECONDS = 4.0
CANDIDATE_LIMIT = 4
RESOLVE_CANDIDATE_LIMIT = 32
COOLDOWN_SECONDS = 30.0


def unavailable():
    return AppError(code='DIRECT_ROOM_EVIDENCE_UNAVAILABLE', message='会话暂不可用，请稍后重试', status_code=503)


class DirectConversationLifecycle:
    def _candidate_window(self, actor, peer, old, candidates, limit=CANDIDATE_LIMIT):
        """Bounded per-process progress, not evidence or distributed singleflight.

        Fingerprint invalidation prevents an altered source list inheriting a
        stale offset. Eviction/restart merely restarts scanning; neither grants
        creation permission based on results from an earlier request.
        """
        key = (self, *sorted((actor, peer)), old)
        if len(candidates) <= 1:
            with _cache_lock:
                _scan_cursors.pop(key, None)
            return candidates
        fingerprint = sha256(repr(candidates).encode()).digest()
        with _cache_lock:
            previous, offset = _scan_cursors.get(key, (None, 0))
            if previous != fingerprint:
                offset = 0
            result = [candidates[(offset + index) % len(candidates)] for index in range(min(limit, len(candidates)))]
            # Advance one starting position even if the first network request
            # consumes the entire budget, so no candidate can be starved.
            _scan_cursors[key] = (fingerprint, (offset + 1) % len(candidates))
            _scan_cursors.move_to_end(key)
            while len(_scan_cursors) > SCAN_CACHE_LIMIT:
                _scan_cursors.popitem(last=False)
            return result

    @contextmanager
    def _before_commit_deadline(self, session, deadline):
        yield
        session.flush()
        if monotonic() >= deadline:
            raise unavailable()

    def _relationship(self, session, actor, peer):
        low, high = sorted((actor, peer))
        friendship = session.scalar(select(Friendship.id).where(Friendship.user_low_id == low, Friendship.user_high_id == high))
        blocked = session.scalar(select(UserBlock.id).where(or_(
            and_(UserBlock.blocker_id == actor, UserBlock.blocked_id == peer),
            and_(UserBlock.blocker_id == peer, UserBlock.blocked_id == actor))))
        active = set(session.scalars(select(User.id).where(User.id.in_([actor, peer]), User.status == AccountStatus.ACTIVE)))
        if friendship is None or blocked is not None or active != {actor, peer}:
            raise AppError(code='DIRECT_ROOM_RECOVERY_FORBIDDEN', message='好友关系不允许恢复', status_code=403)

    def _generation(self, session, actor, peer):
        low, high = sorted((actor, peer))
        return session.scalar(select(DirectRoomGeneration).where(
            DirectRoomGeneration.user_low_id == low, DirectRoomGeneration.user_high_id == high
        ).order_by(DirectRoomGeneration.generation.desc()).limit(1))

    def _sources(self, session, actor, peer):
        low, high = sorted((actor, peer))
        return list(session.scalars(select(DirectConversationRoom.matrix_room_id).where(
            DirectConversationRoom.user_low_id == low, DirectConversationRoom.user_high_id == high
        ).order_by(DirectConversationRoom.created_at, DirectConversationRoom.matrix_room_id)))

    def _expected(self, actor, peer):
        profiles = self.profile_reader.read_public_profiles([actor, peer])
        expected = {getattr(profiles.get(user), 'matrix_user_id', None) for user in (actor, peer)}
        if len(expected) != 2 or not all(isinstance(user, str) and user.startswith('@') for user in expected):
            raise unavailable()
        return expected

    @contextmanager
    def _metadata_budget(self, deadline):
        gateway = self.matrix_gateway
        if gateway is None:
            raise unavailable()
        budget = getattr(gateway, 'metadata_deadline', None)
        if budget:
            with budget(deadline):
                yield
        else:
            yield

    def _state(self, room, deadline):
        if monotonic() >= deadline:
            raise unavailable()
        events = self.matrix_gateway.get_room_state_strict(room)
        if monotonic() >= deadline:
            raise unavailable()
        if not isinstance(events, list):
            raise unavailable()
        state = {}
        for event in events:
            if (not isinstance(event, dict) or not isinstance(event.get('type'), str)
                    or not isinstance(event.get('state_key'), str) or not isinstance(event.get('content'), dict)):
                raise unavailable()
            key = (event['type'], event['state_key'])
            if key in state:
                raise unavailable()
            state[key] = event['content']
        return state

    def _room_health(self, room, expected, deadline):
        state = self._state(room, deadline)
        members = {}
        for (kind, key), content in state.items():
            if kind == 'm.room.member':
                member = content.get('membership')
                if not isinstance(member, str) or member not in {'join', 'invite', 'leave', 'ban', 'knock'}:
                    raise unavailable()
                members[key] = member
        active = {user for user, value in members.items() if value != 'leave'}
        if not active:
            if monotonic() >= deadline:
                raise unavailable()
            details = self.matrix_gateway.get_room_details(room)
            if monotonic() >= deadline:
                raise unavailable()
            if (not isinstance(details, dict) or details.get('room_id') != room
                    or type(details.get('joined_members')) is not int or details['joined_members'] != 0):
                raise unavailable()
            return 'retired', state
        if (not active.issubset(expected) or any(value in {'ban', 'knock'} for value in members.values())
                or state.get(('m.room.encryption', ''), {}).get('algorithm') != 'm.megolm.v1.aes-sha2'):
            return 'unavailable', state
        power = state.get(('m.room.power_levels', ''), {})
        users, events = power.get('users', {}), power.get('events', {})
        if not isinstance(users, dict) or not isinstance(events, dict):
            raise unavailable()
        default, required = power.get('users_default', 0), events.get('m.room.encrypted', power.get('events_default', 0))
        values = [default, required, *[users.get(user, default) for user in expected]]
        if not all(type(value) is int for value in values):
            raise unavailable()
        if any(users.get(user, default) < required for user in expected):
            return 'unavailable', state
        if active == expected and all(members[user] == 'join' for user in expected):
            return 'ready', state
        # At least one joined participant can perform ordinary membership repair.
        if any(members.get(user) == 'join' for user in expected):
            return 'join_required', state
        return 'unavailable', state

    def _old_eligible(self, health, state, expected, reason, departed_matrix_id):
        if reason == 'retired':
            return health == 'retired'
        if reason != 'requester_left' or departed_matrix_id not in expected:
            return False
        # Synapse may discard room state after the final local user leaves.
        # The already accepted strict retirement proof also permits continuing
        # this existing alias; visible invite/join/ban/knock cannot be retired.
        if health == 'retired':
            return True
        other = next(user for user in expected if user != departed_matrix_id)
        return (health in {'join_required', 'retired'}
                and state.get(('m.room.encryption', ''), {}).get('algorithm') == 'm.megolm.v1.aes-sha2'
                and state.get(('m.room.member', departed_matrix_id), {}).get('membership') == 'leave'
                and state.get(('m.room.member', other), {}).get('membership') in {'join', 'leave'})

    def _matrix_id(self, user):
        return getattr(self.profile_reader.read_public_profiles([user]).get(user), 'matrix_user_id', None) if user else None

    def _reply(self, session, actor, peer, status, canonical, generation=None, reservation=None):
        ids = set(self._sources(session, actor, peer))
        if canonical:
            ids.add(canonical.matrix_room_id)
        return dict(status=status, matrix_room_id=canonical.matrix_room_id if canonical and status != 'create_required' else None,
                    revision=canonical.revision if canonical else 0,
                    room_ids=sorted(ids), generation=generation.generation if generation else 0,
                    room_alias_localpart=alias_localpart(reservation) if reservation else None,
                    reservation_id=reservation.id if reservation else None)

    def _switch(self, session, actor, peer, canonical, target, trace):
        old = canonical.matrix_room_id
        for room in (old, target):
            if room not in self._sources(session, actor, peer):
                session.add(DirectConversationRoom(id=str(uuid4()), user_low_id=min(actor, peer), user_high_id=max(actor, peer),
                    matrix_room_id=room, created_at=datetime.now(timezone.utc)))
        canonical.matrix_room_id = target
        canonical.revision += 1
        before, after = {'matrix_room_id': old}, {'matrix_room_id': target}
        session.add(AuditEvent(id=str(uuid4()), actor_id='system:direct-recovery', subject_type='friendship',
            subject_id=canonical.id, action='friend.direct_room_auto_recovered', result='SUCCESS',
            reason_code='DIRECT_ROOM_AUTO_RECOVERY', trace_id=trace, before_data=before,
            after_data={**after, 'trigger_user_id': actor}, created_at=datetime.now(timezone.utc)))
        OutboxPublisher.enqueue(session, topic='friendship.events', event_type='friend.direct_room_auto_recovered',
            aggregate_type='friendship', aggregate_id=canonical.id,
            payload=dict(operator_id='system:direct-recovery', trigger_user_id=actor, before=before, after=after, reason_code='DIRECT_ROOM_AUTO_RECOVERY'))
        session.flush()

    def _resolve(self, actor, peer, attempt, *, create):
        self._validate_direct_peer(actor, peer)
        with self.factory() as session:
            self._relationship(session, actor, peer)
            original = self._canonical(session, actor, peer)
            old = original.matrix_room_id if original else None
            candidates = [room for room in self._sources(session, actor, peer) if room != old]
            pending = self._generation(session, actor, peer)
            if old is None and not create:
                return self._reply(session, actor, peer, 'unavailable', None)
        deadline = monotonic() + PROBE_SECONDS
        with self._metadata_budget(deadline):
            expected = self._expected(actor, peer)
            health, state = self._room_health(old, expected, deadline) if old else (None, {})
            reason, departed = 'retired', None
            if create and pending and pending.expected_old_room_id == old and pending.matrix_room_id is None:
                reason, departed = pending.recovery_reason, pending.departed_user_id
            elif create and health == 'join_required':
                reason, departed = 'requester_left', actor
            eligible = self._old_eligible(health, state, expected, reason, self._matrix_id(departed))
            if health in {'ready', 'join_required', 'unavailable'} and not eligible:
                with self.factory() as session:
                    self._relationship(session, actor, peer)
                    current = self._canonical(session, actor, peer)
                    if current is None or current.matrix_room_id != old:
                        raise unavailable()
                    return self._reply(session, actor, peer, health, current, self._generation(session, actor, peer))
            target = None
            if eligible:
                limit = RESOLVE_CANDIDATE_LIMIT if create else CANDIDATE_LIMIT
                unknown = len(candidates) > limit
                for room in self._candidate_window(actor, peer, old, candidates, limit):
                    try:
                        candidate_health = self._room_health(room, expected, deadline)[0]
                    except AppError:
                        unknown = True
                        continue
                    if candidate_health == 'ready':
                        target = room
                        break
                    if candidate_health == 'unavailable':
                        unknown = True
                if target is None and unknown:
                    raise unavailable()
            with self.factory.begin() as session, self._before_commit_deadline(session, deadline):
                if not create and session.bind.dialect.name == 'postgresql':
                    session.execute(text("SET LOCAL lock_timeout = '100ms'"))
                reservation, inserted = lock_pair(session, actor, peer, V2_PREFIX + attempt)
                self._relationship(session, actor, peer)
                canonical = self._canonical(session, actor, peer)
                generation = self._generation(session, actor, peer)
                if (canonical.matrix_room_id if canonical else None) != old:
                    raise unavailable()
                if old:
                    # Candidate enumeration stays outside lock; only chosen target/old revalidated.
                    if create and generation and generation.expected_old_room_id == old and generation.matrix_room_id is None:
                        reason, departed = generation.recovery_reason, generation.departed_user_id
                    fresh_health, fresh_state = self._room_health(old, expected, deadline)
                    if not self._old_eligible(fresh_health, fresh_state, expected, reason, self._matrix_id(departed)):
                        raise unavailable()
                    if target:
                        if target not in self._sources(session, actor, peer) or self._room_health(target, expected, deadline)[0] != 'ready':
                            raise unavailable()
                        self._relationship(session, actor, peer)
                        self._switch(session, actor, peer, canonical, target, attempt)
                        return self._reply(session, actor, peer, 'ready', canonical, generation)
                    if not create:
                        return self._reply(session, actor, peer, 'unavailable', canonical, generation)
                    self._relationship(session, actor, peer)
                    if generation is None or generation.expected_old_room_id != old or generation.matrix_room_id is not None:
                        generation = DirectRoomGeneration(id=str(uuid4()), user_low_id=min(actor, peer), user_high_id=max(actor, peer),
                            generation=generation.generation + 1 if generation else 1, expected_old_room_id=old,
                            recovery_reason=reason, departed_user_id=departed,
                            created_at=datetime.now(timezone.utc))
                        session.add(generation)
                        self._audit(session, actor, generation.id, 'friend.direct_room_generation_reserved',
                                    'DIRECT_ROOM_GENERATION_RESERVE', attempt)
                    return self._reply(session, actor, peer, 'create_required', canonical, generation, generation)
                if not create:
                    return self._reply(session, actor, peer, 'unavailable', None)
                if inserted or not reservation.attempt_id.startswith(V2_PREFIX):
                    reservation.attempt_id = V2_PREFIX + attempt
                    self._audit(session, actor, reservation.id, 'friend.direct_room_recoverable', 'DIRECT_ROOM_V2_CLAIM', attempt)
                return self._reply(session, actor, peer, 'create_required', None, reservation=reservation)

    def resolve_direct_conversation(self, actor, peer, attempt_id):
        if not _slots.acquire(blocking=False):
            return self._unavailable_reply(actor, peer)
        try:
            try:
                return self._resolve(actor, peer, attempt_id, create=True)
            except AppError as error:
                if error.code in {'DIRECT_ROOM_EVIDENCE_UNAVAILABLE', 'DIRECT_ROOM_INVALID_EVIDENCE'}:
                    return self._unavailable_reply(actor, peer)
                raise
        finally:
            _slots.release()

    def _unavailable_reply(self, actor, peer):
        self._validate_direct_peer(actor, peer)
        with self.factory() as session:
            self._relationship(session, actor, peer)
            return self._reply(session, actor, peer, 'unavailable', self._canonical(session, actor, peer), self._generation(session, actor, peer))

    def reconcile_direct_directory(self, actor, peer):
        if not hasattr(self.matrix_gateway, 'get_room_state_strict'):
            return
        # One admission per service/pair/cooldown across both legacy endpoints.
        key = (self, *sorted((actor, peer)))
        now = monotonic()
        with _cache_lock:
            if _checks.get(key, 0) > now:
                return
            _checks[key] = now + COOLDOWN_SECONDS
            _checks.move_to_end(key)
            while len(_checks) > 4096:
                _checks.popitem(last=False)
        if not _slots.acquire(blocking=False):
            return
        try:
            try:
                self._resolve(actor, peer, str(uuid4()), create=False)
            except (AppError, OperationalError):
                pass  # Read availability and existing canonical survive unknown metadata.
        finally:
            _slots.release()

    def publish_direct_recovery(self, actor, peer, attempt_id, generation, reservation_id, matrix_room_id):
        if not _slots.acquire(blocking=False):
            raise unavailable()
        try:
            return self._publish_direct_recovery(actor, peer, attempt_id, generation, reservation_id, matrix_room_id)
        finally:
            _slots.release()

    def _publish_direct_recovery(self, actor, peer, attempt_id, generation, reservation_id, matrix_room_id):
        self._validate_direct_peer(actor, peer)
        deadline = monotonic() + PROBE_SECONDS
        with self._metadata_budget(deadline), self.factory.begin() as session, self._before_commit_deadline(session, deadline):
            reservation, _ = lock_pair(session, actor, peer, V2_PREFIX + attempt_id)
            self._relationship(session, actor, peer)
            canonical = self._canonical(session, actor, peer)
            latest = self._generation(session, actor, peer)
            record = reservation if generation == 0 else latest
            if record is None or record.id != reservation_id or (generation and record.generation != generation):
                raise AppError(code='DIRECT_ROOM_GENERATION_CONFLICT', message='会话恢复世代已变化', status_code=409)
            if canonical and ((generation == 0 and latest is None and canonical.matrix_room_id == matrix_room_id)
                    or (generation and record.matrix_room_id == matrix_room_id and canonical.matrix_room_id == matrix_room_id)):
                return dict(matrix_room_id=matrix_room_id, generation=generation, revision=canonical.revision)
            if (generation == 0 and canonical is not None) or (generation and
                    (canonical is None or canonical.matrix_room_id != record.expected_old_room_id or record.matrix_room_id is not None)):
                raise AppError(code='DIRECT_ROOM_GENERATION_CONFLICT', message='会话恢复世代已变化', status_code=409)
            expected = self._expected(actor, peer)
            health, state = self._room_health(matrix_room_id, expected, deadline)
            members = {key for (kind, key), content in state.items() if kind == 'm.room.member' and content.get('membership') in {'join', 'invite'}}
            if (health not in {'ready', 'join_required'} or members != expected
                    or state.get(('com.chatflow.direct_reservation', ''), {}).get('reservation_id') != reservation_id
                    or self.matrix_gateway.resolve_room_alias(f'#{alias_localpart(record)}:{self.matrix_server_name}') != matrix_room_id):
                raise unavailable()
            if monotonic() >= deadline:
                raise unavailable()
            if generation:
                old_health, old_state = self._room_health(record.expected_old_room_id, expected, deadline)
                if not self._old_eligible(old_health, old_state, expected, record.recovery_reason,
                                          self._matrix_id(record.departed_user_id)):
                    raise unavailable()
                self._relationship(session, actor, peer)
                self._switch(session, actor, peer, canonical, matrix_room_id, attempt_id)
                record.matrix_room_id = matrix_room_id
            else:
                self._relationship(session, actor, peer)
                canonical = DirectConversation(id=str(uuid4()), user_low_id=min(actor, peer), user_high_id=max(actor, peer),
                    matrix_room_id=matrix_room_id, created_at=datetime.now(timezone.utc))
                session.add(canonical)
                self._remember_direct_room(session, actor, peer, matrix_room_id, attempt_id)
                self._audit(session, actor, canonical.id, 'friend.direct_room_recovered', 'DIRECT_ROOM_RECOVER', attempt_id)
            session.flush()
            return dict(matrix_room_id=matrix_room_id, generation=generation, revision=canonical.revision)
