from __future__ import annotations

from datetime import datetime, timezone
from urllib.parse import quote

from app.core.errors import AppError
from app.modules.identity.models import EmailVerificationChallenge, User
from app.modules.identity.registration import VerificationTokenCodec
from integrations.email_sender import EmailSender


class IdentityEmailVerificationTask:
    def __init__(
        self,
        session_factory,
        *,
        token_codec: VerificationTokenCodec,
        public_base_url: str,
        email_sender: EmailSender,
        now_factory=None,
    ) -> None:
        self._session_factory = session_factory
        self._token_codec = token_codec
        self._public_base_url = public_base_url.rstrip("/")
        self._email_sender = email_sender
        self._now_factory = now_factory or (lambda: datetime.now(timezone.utc))

    def __call__(self, message) -> None:
        if message.event_type != "identity.email.verification.requested":
            raise AppError(
                code="EMAIL_EVENT_UNSUPPORTED",
                message="unsupported identity email event",
                status_code=400,
            )
        challenge_id = message.payload.get("challenge_id")
        if not challenge_id or challenge_id != message.aggregate_id:
            raise AppError(
                code="EMAIL_EVENT_INVALID",
                message="identity email event does not match its aggregate",
                status_code=400,
            )
        code = self._token_codec.verification_code(challenge_id)
        token = self._token_codec.link_token(challenge_id)
        with self._session_factory() as session:
            challenge = session.get(EmailVerificationChallenge, challenge_id)
            if challenge is None:
                raise AppError(
                    code="EMAIL_CHALLENGE_NOT_FOUND",
                    message="email verification challenge not found",
                    status_code=404,
                )
            if challenge.invalidated_at is not None or challenge.consumed_at is not None:
                return
            now = self._as_utc(self._now_factory())
            if self._as_utc(challenge.expires_at) < now:
                return
            expected_code_hash = self._token_codec.code_hash(code)
            expected_link_hash = self._token_codec.link_token_hash(token)
            if (
                challenge.code_hash != expected_code_hash
                or challenge.link_token_hash != expected_link_hash
                or challenge.token_hash != expected_link_hash
            ):
                raise AppError(
                    code="EMAIL_CHALLENGE_HASH_MISMATCH",
                    message="email verification challenge hash mismatch",
                    status_code=409,
                )
            user = session.get(User, challenge.user_id)
            if user is None:
                raise AppError(
                    code="EMAIL_USER_NOT_FOUND",
                    message="email verification user not found",
                    status_code=404,
                )
            link = f"{self._public_base_url}/verify-email?token={quote(token, safe='')}"
            self._email_sender.send_email_verification(
                recipient=user.email,
                code=code,
                link=link,
            )

    @staticmethod
    def _as_utc(value: datetime) -> datetime:
        return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)
