from collections.abc import Callable
from urllib.parse import quote

from app.core.errors import AppError
from app.modules.identity.invitations import hash_opaque_token
from app.modules.identity.models import EmailVerificationChallenge, User
from app.modules.identity.registration import VerificationTokenCodec


class EmailVerificationTask:
    def __init__(
        self,
        session_factory,
        *,
        token_codec: VerificationTokenCodec,
        public_base_url: str,
        sender: Callable[[str, str], None],
    ) -> None:
        self._session_factory = session_factory
        self._token_codec = token_codec
        self._public_base_url = public_base_url.rstrip("/")
        self._sender = sender

    def __call__(self, message) -> None:
        if message.event_type != "identity.email_verification.requested":
            raise AppError(
                code="EMAIL_EVENT_UNSUPPORTED",
                message="unsupported identity email event",
                status_code=400,
            )
        challenge_id = message.payload["challenge_id"]
        token = self._token_codec.issue(challenge_id)
        with self._session_factory() as session:
            challenge = session.get(EmailVerificationChallenge, challenge_id)
            if challenge is None or challenge.token_hash != hash_opaque_token(token):
                raise AppError(
                    code="EMAIL_CHALLENGE_NOT_FOUND",
                    message="email verification challenge not found",
                    status_code=404,
                )
            user = session.get(User, challenge.user_id)
            if user is None:
                raise AppError(
                    code="EMAIL_USER_NOT_FOUND",
                    message="email verification user not found",
                    status_code=404,
                )
            link = f"{self._public_base_url}/verify-email?token={quote(token, safe='')}"
            self._sender(user.email, link)
