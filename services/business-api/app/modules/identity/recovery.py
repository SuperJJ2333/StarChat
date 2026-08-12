from datetime import datetime, timedelta, timezone
from hashlib import sha256
import hmac
from uuid import uuid4

from sqlalchemy import select

from app.core.errors import AppError
from app.core.outbox import OutboxPublisher
from app.modules.identity.enums import HoldType
from app.modules.identity.invitations import hash_opaque_token
from app.modules.identity.models import (
    PasswordResetChallenge,
    RefreshTokenFamily,
    SecurityHold,
    User,
)
from app.modules.identity.passwords import PasswordHasher


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
                select(User).where(User.email_normalized == email.strip().casefold())
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

    def reset(self, token: str, new_password: str) -> str:
        challenge_id = self._token_codec.challenge_id(token)
        if challenge_id is None:
            self._invalid()
        now = self._now_factory()
        with self._session_factory.begin() as session:
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
            if challenge is None:
                self._invalid()
            user = session.get(User, challenge.user_id)
            if user is None:
                self._invalid()
            challenge.consumed_at = now
            user.password_hash = self._password_hasher.hash(new_password)
            user.updated_at = now
            for family in session.scalars(
                select(RefreshTokenFamily).where(
                    RefreshTokenFamily.user_id == user.id,
                    RefreshTokenFamily.revoked_at.is_(None),
                )
            ):
                family.revoked_at = now
                family.revoke_reason = "PASSWORD_RESET"
            session.add(
                SecurityHold(
                    id=str(uuid4()),
                    user_id=user.id,
                    hold_type=HoldType.WITHDRAWAL,
                    reason_code="PASSWORD_RESET",
                    starts_at=now,
                    ends_at=now + timedelta(hours=24),
                    created_at=now,
                )
            )
            return user.id

    @staticmethod
    def _invalid() -> None:
        raise AppError(
            code="PASSWORD_RESET_INVALID",
            message="密码重置链接无效或已过期",
            status_code=400,
        )
