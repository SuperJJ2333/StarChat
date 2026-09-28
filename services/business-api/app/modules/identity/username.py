"""Mutable business handles; immutable account UUID and Matrix identity are preserved."""
from datetime import datetime, timedelta, timezone
from hashlib import sha256
import re

from sqlalchemy import select, text
from sqlalchemy.exc import IntegrityError

from app.core.errors import AppError, FieldError
from app.core.idempotency import IdempotencyService
from app.core.outbox import OutboxPublisher
from app.modules.audit.writer import AuditWriter
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User, UsernameClaim

MIN_LENGTH = 6
MAX_LENGTH = 20
CHANGE_INTERVAL = timedelta(days=365)


def _utc(value):
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def normalize_new_username(value: str, *, location: str = 'body') -> tuple[str, str]:
    clean = value.strip()
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_-]{5,19}', clean):
        raise AppError(code='USERNAME_INVALID',
            message='畅聊号需为6–20位，字母开头，可使用字母、数字、下划线和连字符',
            status_code=422, fields=[FieldError(loc=[location, 'username'],
                msg='畅聊号格式无效', type='value_error')])
    return clean, clean.casefold()


class UsernameClaims:
    """Shared application interface for registration and rename transactions."""
    @staticmethod
    def lock_in_session(session, *normalized_names: str) -> None:
        """Lock handles before any users/claims writes or user-row lock.

        PostgreSQL's transaction-scoped advisory locks serialize the absent
        handle too. Sorting the actual lock keys gives multi-handle callers a
        common order, including the negligible possibility of a hash collision.
        Other supported test engines use their normal serial write transaction.
        """
        if session.get_bind().dialect.name != 'postgresql':
            return
        keys = {int.from_bytes(sha256(b'chatflow/username-owner/v1\0' +
            name.encode('utf-8')).digest()[:8], 'big', signed=True)
            for name in normalized_names}
        for key in sorted(keys):
            session.execute(text('SELECT pg_advisory_xact_lock(CAST(:lock_key AS bigint))'),
                {'lock_key': key})

    @staticmethod
    def owner_in_session(session, normalized: str) -> str | None:
        owner = session.scalar(select(UsernameClaim.owner_user_id).where(
            UsernameClaim.normalized == normalized))
        if owner is not None:
            return owner
        # Supports fixtures and expanded schemas before all historical claims
        # are present; the current username's unique index remains authoritative.
        return session.scalar(select(User.id).where(User.username_normalized == normalized))

    @classmethod
    def require_available_in_session(cls, session, normalized: str,
                                     *, owner_user_id: str | None = None) -> None:
        owner = cls.owner_in_session(session, normalized)
        if owner is not None and owner != owner_user_id:
            cls._taken()

    @classmethod
    def claim_in_session(cls, session, *, normalized: str, owner_user_id: str,
                         now: datetime) -> None:
        cls.require_available_in_session(session, normalized, owner_user_id=owner_user_id)
        existing = session.get(UsernameClaim, normalized)
        if existing is not None:
            return
        try:
            with session.begin_nested():
                session.add(UsernameClaim(normalized=normalized,
                    owner_user_id=owner_user_id, created_at=now))
                session.flush()
        except IntegrityError:
            # Unique PK adjudicates concurrent registration/rename attempts.
            owner = session.scalar(select(UsernameClaim.owner_user_id).where(
                UsernameClaim.normalized == normalized))
            if owner is None:
                raise
            if owner != owner_user_id:
                cls._taken()

    @staticmethod
    def _taken():
        raise AppError(code='USERNAME_TAKEN', message='畅聊号已被使用', status_code=409)


class UsernameService:
    def __init__(self, session_factory, *, now_factory=None):
        self._factory = session_factory
        self._now = now_factory or (lambda: datetime.now(timezone.utc))
        self._audit = AuditWriter(session_factory, now_factory=self._now)

    @staticmethod
    def _active(session, user_id, *, lock=False):
        statement = select(User).where(User.id == user_id)
        if lock:
            statement = statement.with_for_update().execution_options(populate_existing=True)
        user = session.scalar(statement)
        if user is None or user.status != AccountStatus.ACTIVE:
            raise AppError(code='AUTH_REQUIRED', message='需要登录', status_code=401)
        return user

    @staticmethod
    def _next_change(user):
        return None if user.username_changed_at is None else _utc(user.username_changed_at) + CHANGE_INTERVAL

    def policy(self, user_id):
        now = _utc(self._now())
        with self._factory() as session:
            user = self._active(session, user_id)
            next_change = self._next_change(user)
            return {'username': user.username, 'can_change': next_change is None or now >= next_change,
                'next_change_at': next_change, 'min_length': MIN_LENGTH, 'max_length': MAX_LENGTH}

    def availability(self, user_id, username):
        clean, normalized = normalize_new_username(username, location='query')
        with self._factory() as session:
            self._active(session, user_id)
            owner = UsernameClaims.owner_in_session(session, normalized)
            return {'username': clean, 'available': owner is None or owner == user_id}

    def change(self, user_id, username, *, idempotency_key, trace_id, source_ip):
        clean, normalized = normalize_new_username(username)
        if not idempotency_key.strip() or len(idempotency_key) > 128:
            raise AppError(code='IDEMPOTENCY_REQUIRED', message='缺少有效的Idempotency-Key', status_code=422)
        now = _utc(self._now())
        # Preserve exact display case on successful changes; only identity
        # comparison and ownership lookup use casefold.
        request_hash = sha256(clean.encode('ascii')).hexdigest()
        with self._factory.begin() as session:
            observed = self._active(session, user_id).username_normalized
            UsernameClaims.lock_in_session(session, observed, normalized)
            record = IdempotencyService.begin_in_session(session,
                scope=f'identity.username.change:{user_id}', key=idempotency_key,
                request_hash=request_hash, now=now)
            user = self._active(session, user_id, lock=True)
            if record.status == 'COMPLETED':
                return dict(record.response_body)
            now = _utc(self._now())
            next_change = self._next_change(user)
            changed = normalized != user.username_normalized
            if changed and next_change is not None and now < next_change:
                raise AppError(code='USERNAME_CHANGE_COOLDOWN',
                    message='畅聊号每365天只能修改一次', status_code=409)
            if changed and user.username_normalized != observed:
                # A concurrent update must be retried from its current handle;
                # never acquire an additional handle lock after a user-row lock.
                raise AppError(code='USERNAME_CHANGE_CONFLICT',
                    message='账号信息已更新，请重试', status_code=409)
            UsernameClaims.claim_in_session(session, normalized=user.username_normalized,
                owner_user_id=user.id, now=now)
            if changed:
                UsernameClaims.claim_in_session(session, normalized=normalized,
                    owner_user_id=user.id, now=now)
                before = {'username': user.username}
                user.username = clean
                user.username_normalized = normalized
                user.username_changed_at = now
                user.profile_updated_at = now
                user.updated_at = now
                next_change = now + CHANGE_INTERVAL
                self._audit.record_in_session(session, actor_id=user.id,
                    subject_type='user', subject_id=user.id,
                    action='identity.username.changed', result='SUCCESS',
                    reason_code='SELF_USERNAME_CHANGE', trace_id=trace_id, source_ip=source_ip,
                    before=before, after={'username': clean})
                OutboxPublisher.enqueue(session, topic='identity.profile',
                    event_type='identity.profile.changed', aggregate_type='user',
                    aggregate_id=user.id, payload={'user_id': user.id}, now=now)
            receipt = {'username': user.username, 'changed': changed,
                'next_change_at': next_change.isoformat().replace('+00:00', 'Z') if next_change else None}
            IdempotencyService.complete_in_session(record, response_status=200,
                response_body=receipt, now=now)
            return receipt
