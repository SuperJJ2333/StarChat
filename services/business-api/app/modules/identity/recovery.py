from datetime import datetime, timedelta, timezone
from hashlib import sha256
import hmac
from uuid import uuid4

from sqlalchemy import select, update

from app.core.errors import AppError
from app.core.outbox import OutboxPublisher
from app.modules.identity.enums import HoldType
from app.modules.identity.invitations import hash_opaque_token
from app.modules.identity.models import (
    PasswordResetChallenge,
    RefreshTokenFamily,
    SecurityHold,
    User,
    OtpChallenge,
)
from app.modules.identity.passwords import PasswordHasher
from app.modules.audit.writer import AuditWriter


def invalidate_recovery_in_session(session, user_id: str, now: datetime) -> None:
    """Revoke prior recovery proofs after the caller has locked the user."""
    session.execute(update(OtpChallenge).where(
        OtpChallenge.user_id == user_id,
        OtpChallenge.purpose.in_(("password_reset_email", "password_reset_phone", "password_reset_grant")),
        OtpChallenge.consumed_at.is_(None),
    ).values(invalidated_at=now))
    session.execute(update(PasswordResetChallenge).where(
        PasswordResetChallenge.user_id == user_id,
        PasswordResetChallenge.consumed_at.is_(None),
    ).values(consumed_at=now))


class PasswordResetTokenCodec:
    def __init__(self, secret: bytes) -> None:
        if len(secret) < 16:
            raise ValueError("password reset secret must be at least 16 bytes")
        self._secret = secret

    def issue(self, challenge_id: str) -> str:
        signature = hmac.new(self._secret, challenge_id.encode(), sha256).hexdigest()
        return f"{challenge_id}.{signature}"

    def challenge_id(self, token: str) -> str | None:
        try:
            challenge_id, signature = token.rsplit(".", 1)
        except ValueError:
            return None
        expected = hmac.new(self._secret, challenge_id.encode(), sha256).hexdigest()
        return challenge_id if hmac.compare_digest(signature, expected) else None


class PasswordRecoveryService:
    def __init__(
        self,
        session_factory,
        *,
        password_hasher: PasswordHasher,
        token_codec: PasswordResetTokenCodec,
        now_factory=None,
    ) -> None:
        self._session_factory = session_factory
        self._password_hasher = password_hasher
        self._token_codec = token_codec
        self._now_factory = now_factory or (lambda: datetime.now(timezone.utc))

    def request(self, email: str) -> str | None:
        now = self._now_factory()
        with self._session_factory.begin() as session:
            user = session.scalar(
                select(User).where(User.email_normalized == email.strip().casefold()).with_for_update()
            )
            if user is None:
                return None
            challenge_id = str(uuid4())
            token = self._token_codec.issue(challenge_id)
            session.add(
                PasswordResetChallenge(
                    id=challenge_id,
                    user_id=user.id,
                    token_hash=hash_opaque_token(token),
                    expires_at=now + timedelta(hours=1),
                    created_at=now,
                )
            )
            OutboxPublisher.enqueue(
                session,
                topic="identity.email",
                event_type="identity.password_reset.requested",
                aggregate_type="password_reset_challenge",
                aggregate_id=challenge_id,
                payload={"user_id": user.id, "challenge_id": challenge_id},
                now=now,
            )
            return token

    def reset(self, token: str, new_password: str, *, trace_id: str = "unknown", source_ip=None) -> str:
        challenge_id = self._token_codec.challenge_id(token)
        if challenge_id is None:
            self._invalid()
        now = self._now_factory()
        with self._session_factory.begin() as session:
            owner = session.scalar(select(PasswordResetChallenge.user_id).where(
                PasswordResetChallenge.id == challenge_id))
            if owner is None:
                self._invalid()
            user = session.scalar(select(User).where(User.id == owner).with_for_update())
            challenge = session.scalar(
                select(PasswordResetChallenge)
                .where(
                    PasswordResetChallenge.id == challenge_id,
                    PasswordResetChallenge.token_hash == hash_opaque_token(token),
                    PasswordResetChallenge.consumed_at.is_(None),
                    PasswordResetChallenge.expires_at >= now,
                )
                .with_for_update()
            )
            now = self._now_factory()
            expires = challenge.expires_at if challenge is not None else None
            if expires is not None and expires.tzinfo is None:
                expires = expires.replace(tzinfo=timezone.utc)
            if challenge is None or expires <= now or challenge.user_id != owner:
                self._invalid()
            if user is None:
                self._invalid()
            challenge.consumed_at = now
            self.reset_in_session(session, user, new_password, trace_id=trace_id, source_ip=source_ip)
            return user.id

    def reset_in_session(self, session, user: User, new_password: str, *,
                         trace_id: str = "unknown", source_ip=None) -> None:
        """Apply the shared business password reset inside a user-locked transaction."""
        if not isinstance(new_password, str) or not 12 <= len(new_password) <= 256:
            raise AppError(code="PASSWORD_INVALID", message="密码须为12至256位", status_code=422)
        now = self._now_factory()
        user.password_hash = self._password_hasher.hash(new_password)
        user.updated_at = now
        session.execute(update(RefreshTokenFamily).where(
            RefreshTokenFamily.user_id == user.id,
            RefreshTokenFamily.revoked_at.is_(None),
        ).values(revoked_at=now, revoke_reason="PASSWORD_RESET"))
        session.add(SecurityHold(id=str(uuid4()), user_id=user.id,
            hold_type=HoldType.WITHDRAWAL, reason_code="PASSWORD_RESET",
            starts_at=now, ends_at=now + timedelta(hours=24), created_at=now))
        invalidate_recovery_in_session(session, user.id, now)
        AuditWriter(self._session_factory, now_factory=self._now_factory).record_in_session(
            session, actor_id=user.id, subject_type="user", subject_id=user.id,
            action="identity.password.reset", result="SUCCESS", reason_code="PASSWORD_RESET",
            trace_id=trace_id, source_ip=source_ip)
        OutboxPublisher.enqueue(session, topic="identity.account_credentials",
            event_type="identity.password.reset", aggregate_type="user", aggregate_id=user.id,
            payload={"user_id": user.id, "reason_code": "PASSWORD_RESET"}, now=now)

    @staticmethod
    def _invalid() -> None:
        raise AppError(
            code="PASSWORD_RESET_INVALID",
            message="密码重置链接无效或已过期",
            status_code=400,
        )
