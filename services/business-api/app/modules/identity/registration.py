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
from app.modules.identity.invitations import InvitationService, hash_opaque_token
from app.modules.identity.models import (
    EmailVerificationChallenge,
    ReferralBinding,
    User,
)
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.profile_text import registration_nickname, valid_nickname


def phone_registration_user_id(session, registration_session: str) -> str | None:
    record = session.scalar(select(IdempotencyRecord).where(
        IdempotencyRecord.scope == "identity.registration",
        IdempotencyRecord.status == "COMPLETED",
        IdempotencyRecord.response_body["registration_session"].as_string() == registration_session,
    ))
    return (record.response_body or {}).get("phone_user_id") if record else None


@dataclass(frozen=True)
class RegistrationResult:
    user_id: str
    registration_session: str
    status: AccountStatus
    resend_after_seconds: int
    verification_token: str | None = None
    # 好友推荐码是否成功绑定（重放路径恒为 False，审计不重复记录）。
    referral_bound: bool = False
    replayed: bool = False


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
        referral_codec=None,
    ) -> None:
        self._session_factory = session_factory
        self._invitation_service = invitation_service
        self._password_hasher = password_hasher
        self._token_codec = token_codec
        self._now_factory = now_factory or (lambda: datetime.now(timezone.utc))
        # ReferralService（可选）：好友推荐码绑定，与用户创建同事务提交。
        self._referral_service = referral_service
        # ReferralCodec（可选）：识别"某用户的个人邀请码"以推导邀请关系。
        self._referral_codec = referral_codec

    def create_verified_phone_in_session(self, session, *, phone: str,
                                         invitation_code: str, now: datetime) -> User:
        """Called only inside the successful OTP consumption transaction."""
        invitation = self._invitation_service.consume_in_session(
            session, code=invitation_code, now=now)
        handle = 'p' + self._token_codec.digest(
            purpose='phone-public-handle', value=phone)[:24]
        # A user may have manually claimed the deterministic handle. Keep the
        # public identifier opaque without exposing the phone on collisions.
        if session.scalar(select(User.id).where(User.username_normalized == handle)):
            handle += secrets.token_hex(6)
        user = User(id=str(uuid4()), username=handle, username_normalized=handle,
            nickname='畅聊用户' + phone[-4:], email=None, email_normalized=None,
            phone=phone, phone_normalized=phone, phone_verified_at=now,
            password_hash=self._password_hasher.hash(secrets.token_urlsafe(48)),
            status=AccountStatus.PENDING_MATRIX, created_at=now, updated_at=now)
        session.add(user)
        session.flush()
        self._bind_invitation_owner_in_session(session, invitation=invitation,
            invited_user_id=user.id, now=now)
        from app.modules.audit.writer import AuditWriter
        AuditWriter(self._session_factory).record_in_session(session,
            actor_id=user.id, subject_type='user', subject_id=user.id,
            action='identity.registration.created', result='SUCCESS',
            reason_code='PHONE_OTP_ONBOARDING', trace_id=str(uuid4()))
        return user

    def _registration_request_hash(
        self,
        *,
        email_normalized: str,
        phone_normalized: str | None,
        invitation_code: str,
        nickname_clean: str,
        password: str,
        referral_code_clean: str | None,
        username_normalized: str,
    ) -> str:
        payload = json.dumps(
            {
                "email": email_normalized or None,
                **({"phone": phone_normalized} if phone_normalized is not None else {}),
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
        return self._token_codec.digest(
            purpose="registration-idempotency", value=payload
        )

    def register(
        self,
        *,
        username: str,
        nickname: str | None = None,
        email: str | None = None,
        password: str,
        invitation_code: str,
        idempotency_key: str,
        referral_code: str | None = None,
        phone: str | None = None,
    ) -> RegistrationResult:
        username_clean = username.strip()
        legacy_nickname_clean = (nickname or username_clean).strip()
        nickname_clean = registration_nickname(nickname, username_clean)
        # ADR-0075：邮箱或中国大陆手机号二选一注册；禁止虚构邮箱占位。
        phone_normalized = None
        if phone is not None:
            from app.modules.identity.phone import normalize_phone

            phone_normalized = normalize_phone(phone)
        email_clean = (email or "").strip()
        email_normalized = email_clean.casefold()
        if email_clean and phone_normalized is not None:
            raise AppError(code="REGISTRATION_INVALID", message="邮箱或手机号只能选择一种", status_code=422)
        if not email_clean and phone_normalized is None:
            raise AppError(code="REGISTRATION_INVALID", message="注册信息无效", status_code=422,
                fields=[FieldError(loc=["body", "email"], msg="需要邮箱或手机号之一", type="value_error")])
        username_normalized = username_clean.casefold()
        idempotency_key_clean = idempotency_key.strip()
        fields: list[FieldError] = []
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{2,63}", username_clean):
            fields.append(FieldError(loc=["body", "username"], msg="畅聊号格式无效", type="value_error"))
        if not nickname_clean:
            fields.append(FieldError(loc=["body", "nickname"], msg="昵称最多支持12个字符", type="value_error"))
        if email_clean and not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", email_clean):
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
        hash_fields = dict(
            email_normalized=email_normalized,
            phone_normalized=phone_normalized,
            invitation_code=invitation_code,
            password=password,
            referral_code_clean=referral_code_clean,
            username_normalized=username_normalized,
        )
        request_hash = self._registration_request_hash(
            nickname_clean=nickname_clean, **hash_fields
        )
        legacy_hash = self._registration_request_hash(
            nickname_clean=legacy_nickname_clean, **hash_fields
        )
        user_id = str(uuid4())
        challenge_id = str(uuid4())
        token = self._token_codec.link_token(challenge_id)
        code = self._token_codec.verification_code(challenge_id)
        registration_session = secrets.token_urlsafe(32)
        public_response = {
            "registration_session": registration_session,
            "status": (AccountStatus.PENDING_EMAIL if email_clean else AccountStatus.PENDING_PHONE).value,
            "resend_after_seconds": 60,
        }
        try:
            with self._session_factory.begin() as session:
                previous = session.scalar(
                    select(IdempotencyRecord)
                    .where(
                        IdempotencyRecord.scope == "identity.registration",
                        IdempotencyRecord.idempotency_key == idempotency_key_clean,
                    )
                    .with_for_update()
                )
                if previous is not None:
                    if previous.status != "COMPLETED" or previous.request_hash not in (
                        request_hash, legacy_hash
                    ):
                        raise AppError(
                            code="IDEMPOTENCY_CONFLICT",
                            message="幂等键已用于不同的注册请求",
                            status_code=409,
                        )
                    return self._replayed_result(session, previous)
                if not valid_nickname(nickname_clean):
                    raise AppError(
                        code="REGISTRATION_INVALID",
                        message="注册信息无效",
                        status_code=422,
                        fields=[FieldError(loc=["body", "nickname"], msg="昵称最多支持12个字符", type="value_error")],
                    )
                idempotency_record = self._claim_idempotency_key(
                    session,
                    scope="identity.registration",
                    key=idempotency_key_clean,
                    request_hash=request_hash,
                    now=now,
                )
                if idempotency_record.status == "COMPLETED":
                    return self._replayed_result(session, idempotency_record)

                if email_clean:
                    pending_status = AccountStatus.PENDING_EMAIL
                else:
                    pending_status = AccountStatus.PENDING_PHONE
                if phone_normalized is not None:
                    existing_phone = session.scalar(select(User.id).where(User.phone_normalized == phone_normalized))
                    if existing_phone is not None:
                        raise AppError(code="PHONE_TAKEN", message="手机号已被使用", status_code=409)
                session.add(
                    User(
                        id=user_id,
                        username=username_clean,
                        username_normalized=username_normalized,
                        nickname=nickname_clean,
                        email=email_clean or None,
                        email_normalized=email_normalized or None,
                        phone=phone_normalized,
                        phone_normalized=phone_normalized,
                        password_hash=self._password_hasher.hash(password),
                        status=pending_status,
                        created_at=now,
                        updated_at=now,
                    )
                )
                session.flush()
                if not email_clean:
                    # 手机通道：不发邮件挑战；验证经 OTP purpose=registration
                    # （绑定 registration_session），由 PhoneOtpService 完成。
                    idempotency_record.status = "COMPLETED"
                    idempotency_record.response_status = 202
                    idempotency_record.response_body = {**public_response, "phone_user_id": user_id}
                    idempotency_record.completed_at = now
                    session.flush()
                    invitation = self._invitation_service.consume_in_session(
                        session, code=invitation_code, now=now
                    )
                    referral_bound = self._bind_invitation_owner_in_session(
                        session, invitation=invitation, invited_user_id=user_id, now=now)
                    if (not referral_bound and referral_code_clean and self._referral_service is not None):
                        self._referral_service.bind_in_session(session, invited_user_id=user_id,
                            referral_code=referral_code_clean, now=now)
                    session.flush()
                    return RegistrationResult(
                        user_id=user_id,
                        registration_session=registration_session,
                        status=pending_status,
                        resend_after_seconds=60,
                        verification_token=None,
                    )
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
                invitation = self._invitation_service.consume_in_session(
                    session, code=invitation_code, now=now
                )
                # 统一邀请码：注册消耗"某用户的个人邀请码"即与该用户建立
                # 邀请关系（管理员签发的码不建立关系）；旧客户端显式提交
                # referral_code 的路径在未建立关系时兼容受理。
                referral_bound = self._bind_invitation_owner_in_session(
                    session,
                    invitation=invitation,
                    invited_user_id=user_id,
                    now=now,
                )
                if (
                    not referral_bound
                    and referral_code_clean
                    and self._referral_service is not None
                ):
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

    def _bind_invitation_owner_in_session(
        self, session, *, invitation, invited_user_id: str, now: datetime
    ) -> bool:
        """个人邀请码归属人绑定（统一邀请码体系，规格 §6.2）。

        仅当消耗的邀请码确为某用户的固定个人码（code_hash 等于其
        derive_static 派生值）且归属人 ACTIVE、非本人时写入绑定；
        管理员签发码、异常状态一律静默跳过。已绑定（唯一约束）幂等返回。
        """
        codec = self._referral_codec
        if codec is None:
            return False
        owner_id = invitation.created_by
        if owner_id == invited_user_id:
            return False
        if invitation.code_hash != hash_opaque_token(
            codec.derive_static(owner_id)
        ):
            return False  # 非个人码（管理员签发）。
        owner = session.get(User, owner_id)
        if owner is None or owner.status != AccountStatus.ACTIVE:
            return False
        try:
            # SAVEPOINT：绑定失败（重复等防御场景）只回滚本段，
            # 绝不影响同一事务内的用户创建。
            with session.begin_nested():
                session.add(
                    ReferralBinding(
                        id=str(uuid4()),
                        inviter_user_id=owner_id,
                        invited_user_id=invited_user_id,
                        code_hash=invitation.code_hash,
                        code_window_index=0,
                        status="ACTIVE",
                        reward_state="NOT_CONFIGURED",
                        bound_at=now,
                        created_at=now,
                    )
                )
                session.flush()
        except IntegrityError:
            return False
        return True

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
        phone: str | None = None,
    ) -> None:
        email_clean = (email or "").strip()
        if phone is not None:
            from app.modules.identity.phone import normalize_phone
            phone = normalize_phone(phone)
        if email_clean and phone is not None:
            raise AppError(code="REGISTRATION_INVALID", message="邮箱或手机号只能选择一种", status_code=422)
        if email_clean and not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", email_clean):
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
        if not email_clean and phone is None:
            raise AppError(code="REGISTRATION_INVALID", message="注册信息无效", status_code=422,
                fields=[FieldError(loc=["body", "email"], msg="需要邮箱或手机号之一", type="value_error")])
        username_clean = username.strip()
        username_normalized = username_clean.casefold()
        legacy_nickname_clean = (nickname or username_clean).strip()
        nickname_clean = registration_nickname(nickname, username_clean)
        hash_fields = dict(
            email_normalized=email_clean.casefold(),
            phone_normalized=phone,
            invitation_code=invitation_code,
            password=password,
            referral_code_clean=(referral_code or "").strip().upper() or None,
            username_normalized=username_normalized,
        )
        request_hash = self._registration_request_hash(
            nickname_clean=nickname_clean, **hash_fields
        )
        legacy_hash = self._registration_request_hash(
            nickname_clean=legacy_nickname_clean, **hash_fields
        )
        with self._session_factory() as session:
            existing_email = session.scalar(
                select(User.id).where(User.email_normalized == email_clean.casefold())
            )
            existing_username = session.scalar(
                select(User.id).where(User.username_normalized == username_normalized)
            )
            previous = session.scalar(
                select(IdempotencyRecord).where(
                    IdempotencyRecord.scope == "identity.registration",
                    IdempotencyRecord.idempotency_key == idempotency_key.strip(),
                )
            )
        if previous is not None:
            if previous.status == "COMPLETED" and previous.request_hash in (
                request_hash, legacy_hash
            ):
                return
            raise AppError(
                code="IDEMPOTENCY_CONFLICT",
                message="幂等键已用于不同的注册请求",
                status_code=409,
            )
        if not valid_nickname(nickname_clean):
            raise AppError(
                code="REGISTRATION_INVALID",
                message="注册信息无效",
                status_code=422,
                fields=[FieldError(loc=["body", "nickname"], msg="昵称最多支持12个字符", type="value_error")],
            )
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
        if response.get("phone_user_id"):
            return RegistrationResult(user_id=response["phone_user_id"], registration_session=registration_session,
                status=AccountStatus(response["status"]), resend_after_seconds=int(response["resend_after_seconds"]),
                replayed=True)
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
            replayed=True,
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

    def change_email(
        self,
        *,
        registration_session: str,
        new_email: str,
        idempotency_key: str,
    ) -> RegistrationStatusResult:
        """BUG-12（D4 已批准）：邮箱验证完成前允许更换邮箱。

        作废旧验证挑战、更新账号邮箱，并把新验证码发到新邮箱；
        同一 registration_session 继续有效（客户端无感）。邮箱验证
        通过（账号离开 PENDING_EMAIL）后不再支持在此换邮箱。
        """
        now = self._now_factory()
        email_clean = new_email.strip()
        email_normalized = email_clean.casefold()
        request_hash = self._token_codec.digest(
            purpose="identity.email-verification.change-email",
            value=f"{registration_session}:{email_normalized}",
        )
        deferred_error: AppError | None = None
        result: RegistrationStatusResult | None = None
        with self._session_factory.begin() as session:
            record = RegistrationService._claim_idempotency_key(
                session,
                scope="identity.email-verification.change-email",
                key=idempotency_key.strip(),
                request_hash=request_hash,
                now=now,
            )
            if record.status == "COMPLETED":
                return self._status_replay(record)
            if not email_clean or len(email_clean) > 320 or "@" not in email_clean:
                deferred_error = self._error("EMAIL_INVALID", "邮箱格式无效")
            else:
                challenge = self._find_challenge(session, registration_session, for_update=True)
                if challenge is None or challenge.consumed_at is not None:
                    deferred_error = self._error("EMAIL_VERIFICATION_INVALID", "注册会话无效")
                else:
                    user = session.get(User, challenge.user_id)
                    if user is None or user.status != AccountStatus.PENDING_EMAIL:
                        # 已验证/已进入后续阶段的账号不能在此换邮箱（走换绑流程）。
                        deferred_error = self._error("EMAIL_VERIFICATION_INVALID", "注册会话无效")
                    elif session.scalar(
                        select(User.id).where(
                            User.email_normalized == email_normalized,
                            User.id != user.id,
                        )
                    ):
                        deferred_error = AppError(
                            code="EMAIL_ALREADY_REGISTERED",
                            message="该邮箱已被使用",
                            status_code=409,
                        )
            if deferred_error is None:
                # 作废旧挑战并更新邮箱，然后给同一注册会话签发新挑战。
                challenge.invalidated_at = now
                challenge.registration_session_hash = None
                user.email = email_clean
                user.email_normalized = email_normalized
                user.updated_at = now
                session.flush()
                challenge_id = str(uuid4())
                code = self._token_codec.verification_code(challenge_id)
                token = self._token_codec.link_token(challenge_id)
                session.add(
                    EmailVerificationChallenge(
                        id=challenge_id,
                        user_id=user.id,
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
                    payload={"user_id": user.id, "challenge_id": challenge_id},
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
            raise RuntimeError("email change completed without a result")
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
