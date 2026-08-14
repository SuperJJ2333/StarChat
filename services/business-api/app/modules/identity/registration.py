from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from hashlib import sha256
import hmac
import json
import secrets
from uuid import uuid4

from sqlalchemy.exc import IntegrityError
from sqlalchemy import select

from app.core.errors import AppError
from app.core.idempotency import IdempotencyRecord
from app.core.outbox import OutboxPublisher
from app.modules.identity.enums import AccountStatus
from app.modules.identity.invitations import InvitationService, hash_opaque_token
from app.modules.identity.models import EmailVerificationChallenge, User
from app.modules.identity.passwords import PasswordHasher


@dataclass(frozen=True)
class RegistrationResult:
    user_id: str
    registration_session: str
    status: AccountStatus
    resend_after_seconds: int
    verification_token: str | None = None


class VerificationTokenCodec:
    def __init__(self, secret: bytes) -> None:
        if len(secret) < 16:
            raise ValueError("verification token secret must be at least 16 bytes")
        self._secret = secret

    def issue(self, challenge_id: str) -> str:
        signature = hmac.new(self._secret, challenge_id.encode("utf-8"), sha256).hexdigest()
        return f"{challenge_id}.{signature}"

    def challenge_id(self, token: str) -> str | None:
        try:
            challenge_id, signature = token.rsplit(".", 1)
        except ValueError:
            return None
        expected = hmac.new(self._secret, challenge_id.encode("utf-8"), sha256).hexdigest()
        return challenge_id if hmac.compare_digest(signature, expected) else None

    def digest(self, *, purpose: str, value: str) -> str:
        payload = f"{purpose}\0{value}".encode("utf-8")
        return hmac.new(self._secret, payload, sha256).hexdigest()


class RegistrationService:
    def __init__(
        self,
        session_factory,
        *,
        invitation_service: InvitationService,
        password_hasher: PasswordHasher,
        token_codec: VerificationTokenCodec,
        now_factory=None,
    ) -> None:
        self._session_factory = session_factory
        self._invitation_service = invitation_service
        self._password_hasher = password_hasher
        self._token_codec = token_codec
        self._now_factory = now_factory or (lambda: datetime.now(timezone.utc))

    def register(
        self,
        *,
        username: str,
        email: str,
        password: str,
        invitation_code: str,
        idempotency_key: str,
    ) -> RegistrationResult:
        username_clean = username.strip()
        email_clean = email.strip()
        username_normalized = username_clean.casefold()
        email_normalized = email_clean.casefold()
        idempotency_key_clean = idempotency_key.strip()
        if not username_clean or "@" not in email_clean:
            raise AppError(code="REGISTRATION_INVALID", message="注册信息无效", status_code=422)
        if not idempotency_key_clean:
            raise AppError(
                code="IDEMPOTENCY_REQUIRED",
                message="缺少 Idempotency-Key",
                status_code=422,
            )

        now = self._now_factory()
        request_payload = json.dumps(
            {
                "email": email_normalized,
                "invitation_code": invitation_code.strip(),
                "password": password,
                "username": username_normalized,
            },
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
        request_hash = self._token_codec.digest(
            purpose="registration-idempotency",
            value=request_payload,
        )
        user_id = str(uuid4())
        challenge_id = str(uuid4())
        token = self._token_codec.issue(challenge_id)
        registration_session = secrets.token_urlsafe(32)
        public_response = {
            "registration_session": registration_session,
            "status": AccountStatus.PENDING_EMAIL.value,
            "resend_after_seconds": 60,
        }
        try:
            with self._session_factory.begin() as session:
                idempotency_record = self._claim_idempotency_key(
                    session,
                    key=idempotency_key_clean,
                    request_hash=request_hash,
                    now=now,
                )
                if idempotency_record.status == "COMPLETED":
                    return self._replayed_result(session, idempotency_record)
                self._invitation_service.consume_in_session(
                    session, code=invitation_code, now=now
                )
                session.add(
                    User(
                        id=user_id,
                        username=username_clean,
                        username_normalized=username_normalized,
                        email=email_clean,
                        email_normalized=email_normalized,
                        password_hash=self._password_hasher.hash(password),
                        status=AccountStatus.PENDING_EMAIL,
                        created_at=now,
                        updated_at=now,
                    )
                )
                session.add(
                    EmailVerificationChallenge(
                        id=challenge_id,
                        user_id=user_id,
                        token_hash=hash_opaque_token(token),
                        registration_session_hash=hash_opaque_token(registration_session),
                        expires_at=now + timedelta(hours=24),
                        resend_available_at=now + timedelta(seconds=60),
                        attempt_count=0,
                        created_at=now,
                    )
                )
                OutboxPublisher.enqueue(
                    session,
                    topic="identity.email",
                    event_type="identity.email_verification.requested",
                    aggregate_type="email_verification_challenge",
                    aggregate_id=challenge_id,
                    payload={"user_id": user_id, "challenge_id": challenge_id},
                    now=now,
                )
                idempotency_record.status = "COMPLETED"
                idempotency_record.response_status = 202
                idempotency_record.response_body = public_response
                idempotency_record.completed_at = now
        except IntegrityError as exc:
            raise AppError(
                code="REGISTRATION_CONFLICT",
                message="用户名或邮箱已被使用",
                status_code=409,
            ) from exc
        return RegistrationResult(
            user_id=user_id,
            registration_session=registration_session,
            status=AccountStatus.PENDING_EMAIL,
            resend_after_seconds=60,
            verification_token=token,
        )

    @staticmethod
    def _claim_idempotency_key(session, *, key: str, request_hash: str, now: datetime):
        record = IdempotencyRecord(
            id=str(uuid4()),
            scope="identity.registration",
            idempotency_key=key,
            request_hash=request_hash,
            status="IN_PROGRESS",
            created_at=now,
        )
        try:
            with session.begin_nested():
                session.add(record)
                session.flush()
            return record
        except IntegrityError:
            existing = session.scalar(
                select(IdempotencyRecord)
                .where(
                    IdempotencyRecord.scope == "identity.registration",
                    IdempotencyRecord.idempotency_key == key,
                )
                .with_for_update()
            )
            if existing is None:
                raise
            if existing.request_hash != request_hash or existing.status != "COMPLETED":
                raise AppError(
                    code="IDEMPOTENCY_CONFLICT",
                    message="幂等键已用于不同的注册请求",
                    status_code=409,
                )
            return existing

    @staticmethod
    def _replayed_result(session, record: IdempotencyRecord) -> RegistrationResult:
        response = record.response_body or {}
        registration_session = response.get("registration_session")
        if not isinstance(registration_session, str):
            raise RuntimeError("completed registration is missing its public session")
        challenge = session.scalar(
            select(EmailVerificationChallenge).where(
                EmailVerificationChallenge.registration_session_hash
                == hash_opaque_token(registration_session)
            )
        )
        if challenge is None:
            raise RuntimeError("completed registration is missing its verification challenge")
        return RegistrationResult(
            user_id=challenge.user_id,
            registration_session=registration_session,
            status=AccountStatus(response["status"]),
            resend_after_seconds=int(response["resend_after_seconds"]),
        )


class EmailVerificationService:
    def __init__(self, session_factory, *, token_codec: VerificationTokenCodec, now_factory=None) -> None:
        self._session_factory = session_factory
        self._token_codec = token_codec
        self._now_factory = now_factory or (lambda: datetime.now(timezone.utc))

    def verify(self, token: str) -> str:
        challenge_id = self._token_codec.challenge_id(token)
        if challenge_id is None:
            self._invalid()
        now = self._now_factory()
        with self._session_factory.begin() as session:
            challenge = session.scalar(
                select(EmailVerificationChallenge)
                .where(
                    EmailVerificationChallenge.id == challenge_id,
                    EmailVerificationChallenge.token_hash == hash_opaque_token(token),
                    EmailVerificationChallenge.consumed_at.is_(None),
                    EmailVerificationChallenge.expires_at >= now,
                )
                .with_for_update()
            )
            if challenge is None:
                self._invalid()
            user = session.get(User, challenge.user_id)
            if user is None or user.status != AccountStatus.PENDING_EMAIL:
                self._invalid()
            challenge.consumed_at = now
            user.email_verified_at = now
            user.status = AccountStatus.PENDING_MATRIX
            user.updated_at = now
            OutboxPublisher.enqueue(
                session,
                topic="identity.matrix",
                event_type="identity.matrix_provision.requested",
                aggregate_type="user",
                aggregate_id=user.id,
                payload={"user_id": user.id},
                now=now,
            )
            return user.id

    @staticmethod
    def _invalid() -> None:
        raise AppError(
            code="EMAIL_VERIFICATION_INVALID",
            message="邮箱验证链接无效或已过期",
            status_code=400,
        )
