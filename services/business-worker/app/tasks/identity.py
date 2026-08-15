from __future__ import annotations

from datetime import datetime, timezone
from urllib.parse import quote

from sqlalchemy import select

from app.core.errors import AppError
from app.modules.identity.models import EmailVerificationChallenge, User
from app.modules.identity.registration import VerificationTokenCodec
from app.modules.identity.enums import AccountStatus
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


class MatrixProfileSyncTask:
    _MIME_BY_SUFFIX = {
        ".jpg": "image/jpeg",
        ".png": "image/png",
        ".webp": "image/webp",
    }

    def __init__(
        self,
        session_factory,
        *,
        gateway,
        avatar_reader,
        now_factory=None,
    ) -> None:
        self._session_factory = session_factory
        self._gateway = gateway
        self._avatar_reader = avatar_reader
        self._now_factory = now_factory or (lambda: datetime.now(timezone.utc))

    def __call__(self, message) -> None:
        user_id = message.payload.get("user_id")
        if (
            message.event_type != "identity.profile.changed"
            or message.aggregate_type != "user"
            or not user_id
            or message.aggregate_id != user_id
        ):
            raise AppError(
                code="MATRIX_PROFILE_EVENT_INVALID",
                message="Matrix profile event does not match its aggregate",
                status_code=400,
            )

        with self._session_factory() as session:
            user = session.get(User, user_id)
            if (
                user is None
                or user.status != AccountStatus.ACTIVE
                or not user.matrix_user_id
            ):
                raise AppError(
                    code="MATRIX_PROFILE_USER_NOT_READY",
                    message="Matrix profile user is not ready",
                    status_code=409,
                )
            profile_version = self._as_utc(user.profile_updated_at)
            if (
                user.matrix_profile_synced_at is not None
                and self._as_utc(user.matrix_profile_synced_at) >= profile_version
            ):
                return
            matrix_user_id = user.matrix_user_id
            display_name = user.nickname
            avatar_object_key = user.avatar_object_key
            cached_avatar_url = (
                user.matrix_avatar_mxc_uri
                if user.matrix_avatar_source_key == avatar_object_key
                else None
            )

        avatar_url = cached_avatar_url
        if avatar_object_key and not avatar_url:
            mime_type = self._mime_type(avatar_object_key)
            content = self._avatar_reader.get(avatar_object_key)
            avatar_url = self._gateway.upload_profile_media(content, mime_type)
            with self._session_factory.begin() as session:
                user = session.scalar(
                    select(User).where(User.id == user_id).with_for_update()
                )
                if user.avatar_object_key != avatar_object_key:
                    raise AppError(
                        code="MATRIX_PROFILE_CHANGED_DURING_SYNC",
                        message="Business profile changed during Matrix sync",
                        status_code=409,
                    )
                user.matrix_avatar_source_key = avatar_object_key
                user.matrix_avatar_mxc_uri = avatar_url

        self._gateway.set_user_profile(
            matrix_user_id,
            display_name=display_name,
            avatar_url=avatar_url,
        )

        with self._session_factory.begin() as session:
            user = session.scalar(select(User).where(User.id == user_id).with_for_update())
            if (
                self._as_utc(user.profile_updated_at) != profile_version
                or user.avatar_object_key != avatar_object_key
            ):
                return
            if avatar_object_key is None:
                user.matrix_avatar_source_key = None
                user.matrix_avatar_mxc_uri = None
            user.matrix_profile_synced_at = user.profile_updated_at
            user.updated_at = self._now_factory()

    @classmethod
    def _mime_type(cls, object_key: str) -> str:
        suffix = "." + object_key.rsplit(".", 1)[-1].casefold()
        mime_type = cls._MIME_BY_SUFFIX.get(suffix)
        if mime_type is None:
            raise AppError(
                code="MATRIX_PROFILE_AVATAR_INVALID",
                message="Matrix profile avatar format is invalid",
                status_code=422,
            )
        return mime_type

    @staticmethod
    def _as_utc(value: datetime) -> datetime:
        return (
            value.replace(tzinfo=timezone.utc)
            if value.tzinfo is None
            else value.astimezone(timezone.utc)
        )
