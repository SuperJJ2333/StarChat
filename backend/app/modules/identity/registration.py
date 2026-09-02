from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from hashlib import sha256
import hmac
import json
import math
import re
import secrets
from uuid import uuid4

from sqlalchemy.exc import IntegrityError
from sqlalchemy import select

from app.core.errors import AppError, FieldError
from app.core.idempotency import IdempotencyRecord
from app.core.outbox import OutboxPublisher
from app.modules.identity.enums import AccountStatus
from app.modules.identity.invitations import InvitationService
from app.modules.identity.models import EmailVerificationChallenge, User
from app.modules.identity.passwords import PasswordHasher


@dataclass(frozen=True)
class RegistrationResult:
    user_id: str
    registration_session: str
    status: AccountStatus
    resend_after_seconds: int
    verification_token: str | None = None
    # 好友推荐码是否成功绑定（重放路径恒为 False，审计不重复记录）。
    referral_bound: bool = False


@dataclass(frozen=True)
class EmailVerificationResult:
    status: AccountStatus


@dataclass(frozen=True)
class RegistrationStatusResult:
    status: AccountStatus
    resend_after_seconds: int


class VerificationTokenCodec:
    def __init__(self, secret: bytes) -> None:
        if len(secret) < 16:
            raise ValueError("verification token secret must be at least 16 bytes")
        self._secret = secret

    def issue(self, challenge_id: str) -> str:
        signature = hmac.new(self._secret, challenge_id.encode("utf-8"), sha256).hexdigest()
        return f"{challenge_id}.{signature}"

    def link_token(self, challenge_id: str) -> str:
        return self.issue(challenge_id)

    def verification_code(self, challenge_id: str) -> str:
        digest = hmac.new(
            self._secret,
            f"email-verification-code\0{challenge_id}".encode("utf-8"),
            sha256,
        ).digest()
        return f"{int.from_bytes(digest[:8], 'big') % 1_000_000:06d}"

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

    def registration_session_hash(self, registration_session: str) -> str:
        return self.digest(purpose="registration-session", value=registration_session)

    def code_hash(self, code: str) -> str:
        return self.digest(purpose="email-verification-code-hash", value=code)

    def link_token_hash(self, token: str) -> str:
        return self.digest(purpose="email-verification-link-hash", value=token)


class RegistrationService:
    def __init__(
        self,
        session_factory,
        *,
        invitation_service: InvitationService,
        password_hasher: PasswordHasher,
        token_codec: VerificationTokenCodec,
        now_factory=None,
        referral_service=None,
    ) -> None:
        self._session_factory = session_factory
        self._invitation_service = invitation_service
        self._password_hasher = password_hasher
        self._token_codec = token_codec
        self._now_factory = now_factory or (lambda: datetime.now(timezone.utc))
        # ReferralService（可选）：好友推荐码绑定，与用户创建同事务提交。
        self._referral_service = referral_service

    def register(
        self,
        *,
        username: str,
        nickname: str | None = None,
        email: str,
        password: str,
        invitation_code: str,
        idempotency_key: str,
        referral_code: str | None = None,
    ) -> RegistrationResult:
        username_clean = username.strip()
        nickname_clean = (nickname or username_clean).strip()
        email_clean = email.strip()
        username_normalized = username_clean.casefold()
        email_normalized = email_clean.casefold()
        idempotency_key_clean = idempotency_key.strip()
        fields: list[FieldError] = []
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{2,63}", username_clean):
            fields.append(FieldError(loc=["body", "username"], msg="畅聊号格式无效", type="value_error"))
        if not nickname_clean or len(nickname_clean) > 64:
            fields.append(FieldError(loc=["body", "nickname"], msg="用户名长度需为 1-64 个字符", type="value_error"))
        if not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", email_clean):
            fields.append(FieldError(loc=["body", "email"], msg="邮箱格式无效", type="value_error"))
        if len(password) < 12:
            fields.append(FieldError(loc=["body", "password"], msg="密码至少需要 12 位", type="value_error"))
        if fields:
            raise AppError(code="REGISTRATION_INVALID", message="注册信息无效", status_code=422, fields=fields)
        if not idempotency_key_clean:
            raise AppError(
                code="IDEMPOTENCY_REQUIRED",
                message="缺少 Idempotency-Key",
                status_code=422,
            )

        now = self._now_factory()
        referral_code_clean = (
            referral_code.strip().upper() if referral_code else None
        )
        request_payload = json.dumps(
            {
                "email": email_normalized,
                "invitation_code": invitation_code.strip(),
                "nickname": nickname_clean,
                "password": password,
                "referral_code": referral_code_clean,
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
        token = self._token_codec.link_token(challenge_id)
        code = self._token_codec.verification_code(challenge_id)
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
                    scope="identity.registration",
                    key=idempotency_key_clean,
                    request_hash=request_hash,
                    now=now,
                )
                if idempotency_record.status == "COMPLETED":
                    return self._replayed_result(session, idempotency_record)

                session.add(
                    User(
                        id=user_id,
                        username=username_clean,
                        username_normalized=username_normalized,
                        nickname=nickname_clean,
                        email=email_clean,
                        email_normalized=email_normalized,
                        password_hash=self._password_hasher.hash(password),
                        status=AccountStatus.PENDING_EMAIL,
                        created_at=now,
                        updated_at=now,
                    )
                )
                session.flush()
                session.add(
                    EmailVerificationChallenge(
                        id=challenge_id,
                        user_id=user_id,
                        token_hash=self._token_codec.link_token_hash(token),
                        registration_session_hash=self._token_codec.registration_session_hash(
                            registration_session
                        ),
                        code_hash=self._token_codec.code_hash(code),
                        link_token_hash=self._token_codec.link_token_hash(token),
                        expires_at=now + timedelta(minutes=10),
                        resend_available_at=now + timedelta(seconds=60),
                        attempt_count=0,
                        created_at=now,
                    )
                )
                OutboxPublisher.enqueue(
                    session,
                    topic="identity.email",
                    event_type="identity.email.verification.requested",
                    aggregate_type="email_verification_challenge",
                    aggregate_id=challenge_id,
                    payload={"user_id": user_id, "challenge_id": challenge_id},
                    now=now,
                )
                session.flush()
                self._invitation_service.consume_in_session(
                    session, code=invitation_code, now=now
                )
                # 好友推荐码绑定：与用户创建同事务；码无效/邀请人不可用
                # 时不阻断注册（管理员邀请码才是注册硬门槛）。
                referral_bound = False
                if referral_code_clean and self._referral_service is not None:
                    binding = self._referral_service.bind_in_session(
                        session,
                        invited_user_id=user_id,
                        referral_code=referral_code_clean,
                        now=now,
                    )
                    referral_bound = binding is not None
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
            referral_bound=referral_bound,
        )

    def validate_email_eligible(
        self,
        *,
        username: str,
        nickname: str | None,
        email: str,
        password: str,
        invitation_code: str,
        idempotency_key: str,
        referral_code: str | None = None,
    ) -> None:
        email_clean = email.strip()
        if not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", email_clean):
            raise AppError(
                code="REGISTRATION_INVALID",
                message="注册信息无效",
                status_code=422,
                fields=[
                    FieldError(
                        loc=["body", "email"],
                        msg="邮箱格式无效",
                        type="value_error",
                    )
                ],
            )
        request_payload = json.dumps(
            {
                "email": email_clean.casefold(),
                "invitation_code": invitation_code.strip(),
                "nickname": (nickname or username.strip()).strip(),
                "password": password,
                "referral_code": (referral_code or "").strip().upper() or None,
                "username": username.strip().casefold(),
            },
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
        request_hash = self._token_codec.digest(
            purpose="registration-idempotency", value=request_payload
        )
        username_normalized = username.strip().casefold()
        with self._session_factory() as session:
            existing_email = session.scalar(
                select(User.id).where(User.email_normalized == email_clean.casefold())
            )
            existing_username = session.scalar(
                select(User.id).where(User.username_normalized == username_normalized)
            )
            replay = session.scalar(
                select(IdempotencyRecord.id).where(
                    IdempotencyRecord.scope == "identity.registration",
                    IdempotencyRecord.idempotency_key == idempotency_key.strip(),
                    IdempotencyRecord.request_hash == request_hash,
                    IdempotencyRecord.status == "COMPLETED",
                )
            )
        if replay is not None:
            return
        if existing_username is not None:
            raise AppError(code="USERNAME_TAKEN", message="畅聊号已被使用", status_code=409)
        if existing_email is not None:
            raise AppError(code="EMAIL_TAKEN", message="邮箱已被使用", status_code=409)

    @staticmethod
    def _claim_idempotency_key(
        session,
        *,
        scope: str,
        key: str,
        request_hash: str,
        now: datetime,
    ):
        record = IdempotencyRecord(
            id=str(uuid4()),
            scope=scope,
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
                    IdempotencyRecord.scope == scope,
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

    def _replayed_result(self, session, record: IdempotencyRecord) -> RegistrationResult:
        response = record.response_body or {}
        registration_session = response.get("registration_session")
        if not isinstance(registration_session, str):
            raise RuntimeError("completed registration is missing its public session")
        challenge = session.scalar(
            select(EmailVerificationChallenge).where(
                EmailVerificationChallenge.registration_session_hash
                == self._token_codec.registration_session_hash(registration_session)
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

    def verify(
        self,
        *,
        registration_session: str | None,
        code: str | None,
        token: str | None,
        idempotency_key: str,
    ) -> EmailVerificationResult:
        if (code is None) == (token is None):
            raise AppError(
                code="EMAIL_VERIFICATION_CREDENTIAL_REQUIRED",
                message="验证码和验证链接必须且只能提供一种",
                status_code=422,
            )
        now = self._now_factory()
        request_hash = self._token_codec.digest(
            purpose="email-verification-idempotency",
            value=json.dumps(
                {
                    "code": code,
                    "registration_session": registration_session,
                    "token": token,
                },
                separators=(",", ":"),
                sort_keys=True,
            ),
        )
        deferred_error: AppError | None = None
        result: EmailVerificationResult | None = None
        with self._session_factory.begin() as session:
            record = RegistrationService._claim_idempotency_key(
                session,
                scope="identity.email-verification.verify",
                key=idempotency_key.strip(),
                request_hash=request_hash,
                now=now,
            )
            if record.status == "COMPLETED":
                return self._verification_replay(record)
            challenge = (
                self._find_challenge(session, registration_session, for_update=True)
                if registration_session is not None
                else self._find_challenge_by_link_token(session, token or "", for_update=True)
            )
            if challenge is None:
                deferred_error = self._error("EMAIL_VERIFICATION_INVALID", "邮箱验证信息无效")
            else:
                supplied_hash = (
                    self._token_codec.code_hash(code)
                    if code is not None
                    else self._token_codec.link_token_hash(token or "")
                )
                expected_hash = challenge.code_hash if code is not None else challenge.link_token_hash
                if expected_hash is None or not hmac.compare_digest(expected_hash, supplied_hash):
                    challenge.attempt_count = min(5, challenge.attempt_count + 1)
                    error_code = (
                        "EMAIL_VERIFICATION_ATTEMPTS_EXHAUSTED"
                        if challenge.attempt_count >= 5
                        else "EMAIL_VERIFICATION_INVALID"
                    )
                    deferred_error = self._error(error_code, "邮箱验证码或验证链接无效")
                elif challenge.consumed_at is not None:
                    user = session.get(User, challenge.user_id)
                    if user is None or user.status not in (
                        AccountStatus.PENDING_MATRIX,
                        AccountStatus.ACTIVE,
                    ):
                        deferred_error = self._error(
                            "EMAIL_VERIFICATION_INVALID", "邮箱验证状态无效"
                        )
                    else:
                        result = EmailVerificationResult(status=user.status)
                elif challenge.attempt_count >= 5:
                    deferred_error = self._error(
                        "EMAIL_VERIFICATION_ATTEMPTS_EXHAUSTED", "邮箱验证尝试次数已耗尽"
                    )
                elif self._as_utc(challenge.expires_at) < self._as_utc(now):
                    deferred_error = self._error(
                        "EMAIL_VERIFICATION_EXPIRED", "邮箱验证码或验证链接已过期"
                    )
                else:
                    user = session.get(User, challenge.user_id)
                    if user is None or user.status != AccountStatus.PENDING_EMAIL:
                        deferred_error = self._error(
                            "EMAIL_VERIFICATION_INVALID", "邮箱验证状态无效"
                        )
                    else:
                        challenge.consumed_at = now
                        user.email_verified_at = now
                        user.status = AccountStatus.PENDING_MATRIX
                        user.updated_at = now
                        OutboxPublisher.enqueue(
                            session,
                            topic="identity.matrix",
                            event_type="identity.matrix.provision.requested",
                            aggregate_type="user",
                            aggregate_id=user.id,
                            payload={"user_id": user.id},
                            now=now,
                        )
                        result = EmailVerificationResult(status=AccountStatus.PENDING_MATRIX)
            if deferred_error is not None:
                self._complete_error(record, deferred_error, now)
            else:
                self._complete_success(record, {"status": result.status.value}, now)
        if deferred_error is not None:
            raise deferred_error
        if result is None:
            raise RuntimeError("email verification completed without a result")
        return result

    def verify_link(self, token: str) -> EmailVerificationResult:
        token_digest = self._token_codec.digest(
            purpose="email-verification-link-idempotency",
            value=token,
        )
        return self.verify(
            registration_session=None,
            code=None,
            token=token,
            idempotency_key=f"link-{token_digest}",
        )

    def resend(
        self,
        *,
        registration_session: str,
        idempotency_key: str,
    ) -> RegistrationStatusResult:
        now = self._now_factory()
        request_hash = self._token_codec.digest(
            purpose="email-verification-resend-idempotency",
            value=registration_session,
        )
        deferred_error: AppError | None = None
        result: RegistrationStatusResult | None = None
        with self._session_factory.begin() as session:
            record = RegistrationService._claim_idempotency_key(
                session,
                scope="identity.email-verification.resend",
                key=idempotency_key.strip(),
                request_hash=request_hash,
                now=now,
            )
            if record.status == "COMPLETED":
                return self._status_replay(record)
            challenge = self._find_challenge(session, registration_session, for_update=True)
            if challenge is None or challenge.consumed_at is not None:
                deferred_error = self._error("EMAIL_VERIFICATION_INVALID", "邮箱验证信息无效")
            elif self._as_utc(challenge.resend_available_at) > self._as_utc(now):
                deferred_error = self._error(
                    "EMAIL_VERIFICATION_RESEND_TOO_SOON", "请稍后再重新发送验证邮件"
                )
            else:
                challenge.invalidated_at = now
                challenge.registration_session_hash = None
                session.flush()
                challenge_id = str(uuid4())
                code = self._token_codec.verification_code(challenge_id)
                token = self._token_codec.link_token(challenge_id)
                session.add(
                    EmailVerificationChallenge(
                        id=challenge_id,
                        user_id=challenge.user_id,
                        token_hash=self._token_codec.link_token_hash(token),
                        registration_session_hash=self._token_codec.registration_session_hash(
                            registration_session
                        ),
                        code_hash=self._token_codec.code_hash(code),
                        link_token_hash=self._token_codec.link_token_hash(token),
                        expires_at=now + timedelta(minutes=10),
                        resend_available_at=now + timedelta(seconds=60),
                        attempt_count=0,
                        created_at=now,
                    )
                )
                OutboxPublisher.enqueue(
                    session,
                    topic="identity.email",
                    event_type="identity.email.verification.requested",
                    aggregate_type="email_verification_challenge",
                    aggregate_id=challenge_id,
                    payload={"user_id": challenge.user_id, "challenge_id": challenge_id},
                    now=now,
                )
                result = RegistrationStatusResult(
                    status=AccountStatus.PENDING_EMAIL,
                    resend_after_seconds=60,
                )
            if deferred_error is not None:
                self._complete_error(record, deferred_error, now)
            else:
                self._complete_success(
                    record,
                    {
                        "status": result.status.value,
                        "resend_after_seconds": result.resend_after_seconds,
                    },
                    now,
                )
        if deferred_error is not None:
            raise deferred_error
        if result is None:
            raise RuntimeError("email verification resend completed without a result")
        return result

    def status(self, registration_session: str) -> RegistrationStatusResult:
        now = self._now_factory()
        with self._session_factory() as session:
            challenge = self._find_challenge(session, registration_session)
            if challenge is None:
                raise self._error("EMAIL_VERIFICATION_INVALID", "注册会话无效")
            user = session.get(User, challenge.user_id)
            if user is None:
                raise self._error("EMAIL_VERIFICATION_INVALID", "注册会话无效")
            resend_after_seconds = 0
            if user.status == AccountStatus.PENDING_EMAIL and challenge.resend_available_at:
                resend_after_seconds = max(
                    0,
                    math.ceil(
                        (self._as_utc(challenge.resend_available_at) - self._as_utc(now)).total_seconds()
                    ),
                )
            return RegistrationStatusResult(
                status=user.status,
                resend_after_seconds=resend_after_seconds,
            )

    def user_id_for_session(self, registration_session: str) -> str:
        with self._session_factory() as session:
            challenge = self._find_challenge(session, registration_session)
            if challenge is None:
                raise self._error("EMAIL_VERIFICATION_INVALID", "注册会话无效")
            return challenge.user_id

    def user_id_for_token(self, token: str) -> str:
        with self._session_factory() as session:
            challenge = self._find_challenge_by_link_token(session, token)
            if challenge is None:
                raise self._error("EMAIL_VERIFICATION_INVALID", "验证链接无效")
            return challenge.user_id

    def _find_challenge(self, session, registration_session: str, *, for_update=False):
        statement = select(EmailVerificationChallenge).where(
            EmailVerificationChallenge.registration_session_hash
            == self._token_codec.registration_session_hash(registration_session)
        )
        if for_update:
            statement = statement.with_for_update()
        return session.scalar(statement)

    def _find_challenge_by_link_token(self, session, token: str, *, for_update=False):
        statement = select(EmailVerificationChallenge).where(
            EmailVerificationChallenge.link_token_hash
            == self._token_codec.link_token_hash(token),
            EmailVerificationChallenge.invalidated_at.is_(None),
        )
        if for_update:
            statement = statement.with_for_update()
        return session.scalar(statement)

    @staticmethod
    def _complete_success(record, response: dict, now: datetime) -> None:
        record.status = "COMPLETED"
        record.response_status = 202
        record.response_body = response
        record.completed_at = now

    @staticmethod
    def _complete_error(record, error: AppError, now: datetime) -> None:
        record.status = "COMPLETED"
        record.response_status = error.status_code
        record.response_body = {
            "error_code": error.code,
            "error_message": error.message,
        }
        record.completed_at = now

    @staticmethod
    def _verification_replay(record) -> EmailVerificationResult:
        response = record.response_body or {}
        if "error_code" in response:
            raise EmailVerificationService._error(
                response["error_code"], response.get("error_message", "邮箱验证失败")
            )
        return EmailVerificationResult(status=AccountStatus(response["status"]))

    @staticmethod
    def _status_replay(record) -> RegistrationStatusResult:
        response = record.response_body or {}
        if "error_code" in response:
            raise EmailVerificationService._error(
                response["error_code"], response.get("error_message", "邮箱验证失败")
            )
        return RegistrationStatusResult(
            status=AccountStatus(response["status"]),
            resend_after_seconds=int(response["resend_after_seconds"]),
        )

    @staticmethod
    def _as_utc(value: datetime) -> datetime:
        return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)

    @staticmethod
    def _error(code: str, message: str) -> AppError:
        return AppError(code=code, message=message, status_code=400)

    @staticmethod
    def _invalid() -> None:
        raise AppError(
            code="EMAIL_VERIFICATION_INVALID",
            message="邮箱验证链接无效或已过期",
            status_code=400,
        )
