"""ADR-0075：中国大陆手机号归一化、短信 OTP 与短信发送适配接口。

红线：
- OTP 按用途（registration/login/phone_rebind_old/phone_rebind_new/
  email_rebind_old）严格区分，绑定目标与归属（user/registration session），
  限时 5 分钟、尝试 ≤5 次、单次消费（条件更新原子置位）、防重放；
- 发送限频：同目标 10 分钟 ≤3 条、1 小时 ≤5 条；
- 日志/错误绝不携带验证码或完整手机号（脱敏 +86****xxxx）；
- 生产未配置短信供应商时 fail closed（SMS_NOT_CONFIGURED），
  禁止固定验证码或伪发送成功；
- 验证码登录只恢复登录权，不触及 Matrix 密钥/E2EE 恢复边界。
"""
import re
import hmac
from datetime import datetime, timedelta, timezone
from hashlib import sha256
import secrets
from uuid import uuid4

from sqlalchemy import select, update, text

from app.core.errors import AppError

PHONE_CANONICAL = re.compile(r"^1[3-9][0-9]{9}$")
OTP_TTL_SECONDS = 300
OTP_MAX_ATTEMPTS = 5
INVITATION_PROOF_TTL_SECONDS = 300
INVITATION_PROOF_MAX_ATTEMPTS = 5
SEND_WINDOW_10M = 600
SEND_LIMIT_10M = 3
SEND_WINDOW_1H = 3600
SEND_LIMIT_1H = 5


class SmsSender:
    """短信发送适配接口（ADR-0075 决策7）。

    生产接入真实供应商时实现本协议并在装配处注册；测试注入
    RecordingSmsSender。绝不实现“固定验证码/伪发送成功”。
    """

    def send(self, phone: str, code: str, purpose: str) -> None:  # pragma: no cover - 接口
        raise NotImplementedError

    def send_challenge(self, phone: str, code: str, purpose: str, challenge_id: str) -> None:
        self.send(phone, code, purpose)


class NullSmsSender(SmsSender):
    """未配置供应商：fail closed，任何发送尝试都明确失败。"""

    def send(self, phone: str, code: str, purpose: str) -> None:
        raise AppError(code="SMS_NOT_CONFIGURED", message="短信服务未配置", status_code=503)


class RecordingSmsSender(SmsSender):
    """测试替身：记录发送（不落库、不进日志）。"""

    def __init__(self):
        self.messages: list[tuple[str, str, str]] = []

    def send(self, phone: str, code: str, purpose: str) -> None:
        self.messages.append((phone, code, purpose))


def normalize_phone(value: str) -> str:
    """归一化为中国大陆 +86 格式；不合法即 422。"""
    digits = re.sub(r"[ \-\(\)]", "", str(value or ""))
    if digits.startswith("+86"):
        digits = digits[3:]
    elif digits.startswith("86") and len(digits) == 13:
        digits = digits[2:]
    if not PHONE_CANONICAL.fullmatch(digits):
        raise AppError(code="PHONE_INVALID", message="仅支持中国大陆手机号", status_code=422)
    return f"+86{digits}"


def mask_phone(phone: str) -> str:
    return f"{phone[:3]}****{phone[-4:]}" if phone and len(phone) >= 8 else "***"


def _hash_code(code: str, salt: str) -> str:
    return sha256(f"{salt}:{code}".encode()).hexdigest()


class PhoneOtpService:
    """用途绑定的短信 OTP（签发/校验/消费一体）。"""

    PURPOSES = {"registration", "login", "phone_rebind_old", "phone_rebind_new", "email_rebind_old", "staff_activation_phone", "staff_activation_email"}

    def __init__(self, session_factory, *, sender: SmsSender, secret: str, now=None, phone_enabled: bool = True,
                 code_verifier=None, code_deriver=None):
        import app.modules.identity.models as identity_models

        self._models = identity_models
        self._factory = session_factory
        self.sender = sender
        self._secret = secret
        self._now = now or (lambda: datetime.now(timezone.utc))
        self.phone_enabled = phone_enabled
        # 供应商校验路径（ADR-0075 实施补充：阿里云 CheckSmsVerifyCode）。
        # 提供时本地 code_hash 比较被替换为 provider 判定；尝试计数、
        # 用途/目标/会话绑定、单次消费等本地不变量全部保留。
        self.code_verifier = code_verifier
        self.code_deriver = code_deriver

    def _utcnow(self) -> datetime:
        value = self._now()
        return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)

    def issue(self, *, purpose: str, phone: str, user_id: str | None = None,
              registration_session: str | None = None) -> None:
        """签发并“发送”OTP。目标不存在/已注销与存在返回同一 202 语义由
        调用方保证；本方法对真实目标执行全部限频与落库。"""
        if purpose not in self.PURPOSES:
            raise AppError(code="OTP_PURPOSE_INVALID", message="验证码用途无效", status_code=422)
        if not self.phone_enabled:
            raise AppError(code="PHONE_AUTH_DISABLED", message="手机号功能未开启", status_code=503)
        now = self._utcnow()
        challenge_id = str(uuid4())
        code = self.code_deriver(challenge_id) if self.code_deriver else f"{secrets.randbelow(1000000):06d}"
        code_hash = _hash_code(code, self._secret)
        with self._factory.begin() as session:
            OtpChallenge = self._models.OtpChallenge
            if session.get_bind().dialect.name == "postgresql":
                # Serialize quota reservation across API workers, even when
                # there is no challenge row yet. Never put the phone in SQL.
                session.execute(text("SELECT pg_advisory_xact_lock(hashtext(:key))"),
                    {"key": "identity:otp:" + sha256(phone.encode()).hexdigest()})
            # 取数后按 UTC 归一比较（SQLite naive / PG aware 通用）。
            recent = session.scalars(select(OtpChallenge).where(
                OtpChallenge.target == phone,
                OtpChallenge.created_at >= now - timedelta(seconds=SEND_WINDOW_1H))).all()
            recent = [row for row in recent
                if (row.created_at.replace(tzinfo=timezone.utc) if row.created_at.tzinfo is None else row.created_at)
                >= now - timedelta(seconds=SEND_WINDOW_1H)]
            within_10m = sum(1 for row in recent
                if (row.created_at.replace(tzinfo=timezone.utc) if row.created_at.tzinfo is None else row.created_at)
                >= now - timedelta(seconds=SEND_WINDOW_10M))
            if within_10m >= SEND_LIMIT_10M or len(recent) >= SEND_LIMIT_1H:
                raise AppError(code="OTP_SEND_RATE_LIMITED", message="验证码发送过于频繁，请稍后再试", status_code=429)
            session.execute(update(OtpChallenge).where(OtpChallenge.purpose == purpose,
                OtpChallenge.target == phone, OtpChallenge.consumed_at.is_(None)).values(invalidated_at=now))
            session.add(OtpChallenge(id=challenge_id, purpose=purpose, target=phone,
                user_id=user_id, registration_session=registration_session,
                code_hash=code_hash, expires_at=now + timedelta(seconds=OTP_TTL_SECONDS),
                attempts_left=0, created_at=now))
        # Reserve quota durably, but never authenticate a pending/failed delivery.
        try:
            self.sender.send_challenge(phone, code, purpose, challenge_id)
        except Exception:
            with self._factory.begin() as session:
                session.execute(update(OtpChallenge).where(OtpChallenge.id == challenge_id)
                    .values(invalidated_at=self._utcnow()))
            raise
        with self._factory.begin() as session:
            # A newer send may already have invalidated this pending challenge.
            session.execute(update(OtpChallenge).where(OtpChallenge.id == challenge_id,
                OtpChallenge.invalidated_at.is_(None), OtpChallenge.consumed_at.is_(None))
                .values(attempts_left=OTP_MAX_ATTEMPTS))

    def verify_code(self, *, purpose: str, target: str, code: str | None, user_id: str | None = None,
                    registration_session: str | None = None, consume: bool = True, on_verified=None) -> bool:
        """与 issue 对应的校验入口：code 为用户提交的验证码。

        绑定校验：user_id/registration_session 必须与签发时一致（提供即校验）。
        消费原子性：条件 UPDATE ... WHERE consumed_at IS NULL，重放必败。
        """
        now = self._utcnow()
        invalid = False
        with self._factory.begin() as session:
            OtpChallenge = self._models.OtpChallenge
            row = session.scalar(select(OtpChallenge).where(
                OtpChallenge.purpose == purpose, OtpChallenge.target == target,
                OtpChallenge.consumed_at.is_(None), OtpChallenge.invalidated_at.is_(None),
                OtpChallenge.expires_at > now).order_by(OtpChallenge.created_at.desc()).with_for_update())
            if row is None:
                raise AppError(code="OTP_INVALID", message="验证码无效或已过期", status_code=400)
            if user_id is not None and row.user_id != user_id:
                raise AppError(code="OTP_INVALID", message="验证码无效或已过期", status_code=400)
            if registration_session is not None and row.registration_session != registration_session:
                raise AppError(code="OTP_INVALID", message="验证码无效或已过期", status_code=400)
            matched = False
            if row.attempts_left <= 0 or code is None:
                row.attempts_left = max(0, row.attempts_left - 1)
                invalid = True
            else:
                if self.code_verifier is not None and purpose != "email_rebind_old":
                    # 供应商校验：False=不匹配（计一次尝试）；异常=供应商不可达，
                    # 事务回滚 → 不计尝试、不消费（fail-safe）。
                    matched = bool(self.code_verifier(target, purpose, code, row.id))
                else:
                    matched = _hash_code(code, self._secret) == row.code_hash
                if not matched:
                    row.attempts_left = max(0, row.attempts_left - 1)
                    invalid = True
            if matched and consume:
                result = session.execute(update(OtpChallenge).where(
                    OtpChallenge.id == row.id, OtpChallenge.consumed_at.is_(None)).values(consumed_at=now))
                if result.rowcount != 1:
                    raise AppError(code="OTP_INVALID", message="验证码无效或已过期", status_code=400)
                if on_verified is not None:
                    on_verified(session, row)
        if invalid:
            raise AppError(code="OTP_INVALID", message="验证码无效或已过期", status_code=400)
        return True


class PhoneAuthService:
    """ADR-0075：手机号注册验证、验证码登录与换绑会话（服务端持有）。"""

    OLD_VERIF_WINDOW = timedelta(minutes=5)

    def __init__(self, session_factory, *, otp: PhoneOtpService, now=None, email_code_deriver=None, registration=None):
        self._factory = session_factory
        self.otp = otp
        self._now = now or (lambda: datetime.now(timezone.utc))
        # 邮箱验证码派生器（如 VerificationTokenCodec.verification_code）：
        # 提供时邮箱 OTP 由 otp_id 确定性派生——明文只出现在投递事件中由
        # worker 以同一派生器复原，数据库仅存哈希（与邮箱验证码同纪律）。
        self._email_code_deriver = email_code_deriver
        self.registration = registration

    def _utcnow(self) -> datetime:
        value = self._now()
        return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)

    def _user_by_phone(self, session, phone: str):
        from app.modules.identity.models import User

        return session.scalar(select(User).where(User.phone_normalized == phone))

    # -------------------------------------------------------- 注册验证
    def registration_user(self, session, registration_session: str):
        from app.modules.identity.models import User
        from app.modules.identity.registration import phone_registration_user_id

        user_id = phone_registration_user_id(session, registration_session)
        return session.get(User, user_id) if user_id else None

    def request_registration_otp(self, *, registration_session: str) -> dict:
        from app.modules.identity.enums import AccountStatus

        with self._factory() as session:
            user = self.registration_user(session, registration_session)
            if user is None or user.status != AccountStatus.PENDING_PHONE:
                raise AppError(code="PHONE_VERIFICATION_INVALID", message="验证状态无效", status_code=400)
            phone, user_id = user.phone_normalized, user.id
        self.otp.issue(purpose="registration", phone=phone, user_id=user_id,
            registration_session=registration_session)
        return {"status": "accepted"}

    def verify_registration(self, *, registration_session: str, phone: str, code: str) -> dict:
        """手机通道注册验证：消费 OTP → PENDING_MATRIX → Outbox 供 Matrix。"""
        from app.core.outbox import OutboxPublisher
        from app.modules.identity.enums import AccountStatus
        from app.modules.identity.models import User

        normalized = normalize_phone(phone)
        now = self._utcnow()
        with self._factory() as session:
            user = self.registration_user(session, registration_session)
            if user is None or user.phone_normalized != normalized:
                raise AppError(code="PHONE_VERIFICATION_INVALID", message="验证状态无效", status_code=400)
            user_id = user.id

        def complete(session, challenge):
            user = self._user_by_phone(session, normalized)
            if user is None or user.id != user_id or user.status != AccountStatus.PENDING_PHONE:
                raise AppError(code="PHONE_VERIFICATION_INVALID", message="验证状态无效", status_code=400)
            user.phone_verified_at = now
            user.status = AccountStatus.PENDING_MATRIX
            user.updated_at = now
            OutboxPublisher.enqueue(session, topic="identity.matrix",
                event_type="identity.matrix.provision.requested", aggregate_type="user",
                aggregate_id=user.id, payload={"user_id": user.id}, now=now)
        self.otp.verify_code(purpose="registration", target=normalized, code=code,
            user_id=user_id, registration_session=registration_session, on_verified=complete)
        return {"status": AccountStatus.PENDING_MATRIX.value}

    # -------------------------------------------------------- 登录
    def request_login_otp(self, *, phone: str) -> dict:
        normalized = normalize_phone(phone)
        if not self.otp.phone_enabled:
            raise AppError(code="PHONE_AUTH_DISABLED", message="手机号功能未开启", status_code=503)
        if isinstance(self.otp.sender, NullSmsSender):
            raise AppError(code="SMS_NOT_CONFIGURED", message="短信服务未配置", status_code=503)
        from app.modules.identity.enums import AccountStatus
        with self._factory() as session:
            user = self._user_by_phone(session, normalized)
            eligible = user is None or user.status in (
                AccountStatus.ACTIVE, AccountStatus.PENDING_PHONE, AccountStatus.PENDING_MATRIX)
            user_id = user.id if user else None
        if eligible and (user_id is not None or self.registration is not None):
            try:
                self.otp.issue(purpose="login", phone=normalized, user_id=user_id)
            except AppError as error:
                if error.code != "OTP_SEND_RATE_LIMITED":
                    raise
        return {"status": "accepted"}

    def _ticket_digest(self, value: str) -> str:
        return hmac.new(self.otp._secret.encode(),
            ("phone-login-resume:" + value).encode(), sha256).hexdigest()

    def login(self, *, phone: str, code: str, tokens: object, device_key: str,
              device_name: str, invitation_code: str = "", terms_accepted: bool = False,
              allow_invitation_continuation: bool = False, on_new_account=None):
        if not self.otp.phone_enabled:
            raise AppError(code="PHONE_AUTH_DISABLED", message="手机号功能未开启", status_code=503)
        from app.modules.identity.enums import AccountStatus
        from app.modules.identity.models import OtpChallenge
        from app.core.outbox import OutboxPublisher
        normalized = normalize_phone(phone)
        now = self._utcnow()
        result = {}
        ticket = secrets.token_urlsafe(32)

        def complete(session, challenge):
            if session.get_bind().dialect.name == "postgresql":
                session.execute(text("SELECT pg_advisory_xact_lock(hashtext(:key))"),
                    {"key": "identity:onboard:" + sha256(normalized.encode()).hexdigest()})
            user = self._user_by_phone(session, normalized)
            if user is not None and user.status not in (
                    AccountStatus.ACTIVE, AccountStatus.PENDING_PHONE, AccountStatus.PENDING_MATRIX):
                raise AppError(code="CREDENTIALS_INVALID", message="账号或验证码错误", status_code=401)
            if challenge.user_id is not None and (user is None or challenge.user_id != user.id):
                raise AppError(code="OTP_INVALID", message="验证码无效或已过期", status_code=400)
            if user is not None and user.status == AccountStatus.PENDING_PHONE:
                # That separate registration owns its credentials and invitation.
                # A login OTP must never activate an unverified registrant's password.
                raise AppError(code="PHONE_REGISTRATION_INCOMPLETE",
                    message="该手机号已开始注册，请完成原注册验证流程或联系客服", status_code=409)
            if user is None:
                if self.registration is None:
                    raise AppError(code="CREDENTIALS_INVALID", message="账号或验证码错误", status_code=401)
                if allow_invitation_continuation:
                    # The supplier may accept an OTP only once. Commit that
                    # verification together with a short-lived continuation;
                    # invitation corrections must never call it again.
                    session.add(OtpChallenge(id=str(uuid4()), purpose='login_invitation',
                        target=self._ticket_digest(ticket),
                        registration_session=self._ticket_digest(device_key),
                        code_hash=self._ticket_digest(normalized),
                        expires_at=now + timedelta(seconds=INVITATION_PROOF_TTL_SECONDS),
                        attempts_left=INVITATION_PROOF_MAX_ATTEMPTS, created_at=now))
                    result['invitation_verified'] = True
                    return
                if not terms_accepted:
                    raise AppError(code="TERMS_REQUIRED", message="请先阅读并同意用户协议和隐私政策", status_code=422)
                user = self.registration.create_verified_phone_in_session(session,
                    phone=normalized, invitation_code=invitation_code, now=now)
                if on_new_account is not None:
                    on_new_account()
                result['created'] = True
            if result.get('created'):
                user.phone_verified_at = now
                user.status = AccountStatus.PENDING_MATRIX
                user.updated_at = now
                OutboxPublisher.enqueue(session, topic="identity.matrix",
                    event_type="identity.matrix.provision.requested", aggregate_type="user",
                    aggregate_id=user.id, payload={"user_id": user.id}, now=now)
            result['user_id'] = user.id
            if user.status == AccountStatus.PENDING_MATRIX:
                session.add(OtpChallenge(id=str(uuid4()), purpose='login_resume',
                    target=self._ticket_digest(ticket), code_hash=self._ticket_digest(normalized),
                    registration_session=self._ticket_digest(device_key), user_id=user.id,
                    expires_at=now + timedelta(minutes=5), attempts_left=1, created_at=now))
                result['pending'] = True
        self.otp.verify_code(purpose="login", target=normalized, code=code, on_verified=complete)
        if result.get('invitation_verified'):
            return {'status': 'INVITATION_VERIFIED', 'invitation_ticket': ticket}
        if result.get('pending'):
            return {'status': 'PENDING_MATRIX', 'login_ticket': ticket, 'retry_after_seconds': 2}
        return tokens.issue_pair(user_id=result['user_id'], device_key=device_key, display_name=device_name)

    def complete_invitation(self, *, invitation_ticket: str, phone: str,
                            device_key: str, device_name: str, invitation_code: str,
                            terms_accepted: bool, tokens, on_new_account=None):
        """Continue a supplier-verified, single-use phone signup without OTP replay.

        The invitation proof is a 256-bit bearer secret, stored only as an HMAC.
        Its phone and device association is checked before any registration
        write. Successful registration turns this row into the existing
        login_resume proof, so a lost response can be retried with the ticket.
        """
        from app.modules.identity.enums import AccountStatus
        from app.modules.identity.models import OtpChallenge, User
        from app.core.outbox import OutboxPublisher

        if not self.otp.phone_enabled:
            raise AppError(code="PHONE_AUTH_DISABLED", message="手机号功能未开启", status_code=503)
        if self.registration is None:
            raise AppError(code="CREDENTIALS_INVALID", message="账号或验证码错误", status_code=401)
        normalized = normalize_phone(phone)
        now = self._utcnow()
        result = {}
        with self._factory.begin() as session:
            if session.get_bind().dialect.name == 'sqlite':
                # SQLite's legacy transaction mode does not BEGIN for SELECT.
                # Start the outer write transaction before any nested SAVEPOINT
                # so a late proof-expiry rollback also removes the new user.
                session.execute(text('BEGIN IMMEDIATE'))
            proof = session.scalar(select(OtpChallenge).where(
                OtpChallenge.purpose.in_(('login_invitation', 'login_resume')),
                OtpChallenge.target == self._ticket_digest(invitation_ticket),
                OtpChallenge.registration_session == self._ticket_digest(device_key),
                OtpChallenge.consumed_at.is_(None), OtpChallenge.invalidated_at.is_(None),
                OtpChallenge.expires_at > now).with_for_update())
            if proof is None or not hmac.compare_digest(
                    proof.code_hash, self._ticket_digest(normalized)):
                raise AppError(code='INVITATION_TICKET_INVALID',
                    message='验证状态已失效，请重新获取验证码', status_code=401)
            # The SQL predicate uses the time before a possible row-lock wait.
            # Recheck against the clock after acquiring the row so an expired
            # proof cannot authorize registration or a replayed login ticket.
            expires_at = proof.expires_at
            if expires_at.tzinfo is None:
                expires_at = expires_at.replace(tzinfo=timezone.utc)
            else:
                expires_at = expires_at.astimezone(timezone.utc)

            def current_proof_time():
                current = self._utcnow()
                if expires_at <= current:
                    raise AppError(code='INVITATION_TICKET_INVALID',
                        message='验证状态已失效，请重新获取验证码', status_code=401)
                return current

            now = current_proof_time()
            if proof.purpose == 'login_resume':
                # An invitation completion response may have been lost. The
                # same ticket is now safe to use at /login/complete.
                user = session.get(User, proof.user_id)
                if user is None or user.status not in (
                        AccountStatus.PENDING_MATRIX, AccountStatus.ACTIVE) or (
                        user.phone_normalized != normalized or user.phone_verified_at is None):
                    raise AppError(code='INVITATION_TICKET_INVALID',
                        message='验证状态已失效，请重新获取验证码', status_code=401)
                result['completed'] = True
            elif proof.attempts_left <= 0:
                raise AppError(code='INVITATION_TICKET_INVALID',
                    message='验证状态已失效，请重新获取验证码', status_code=401)
            elif not terms_accepted:
                result['correction'] = 'TERMS_REQUIRED'
            elif not invitation_code.strip():
                result['correction'] = 'INVITATION_REQUIRED'
            else:
                if session.get_bind().dialect.name == 'postgresql':
                    session.execute(text('SELECT pg_advisory_xact_lock(hashtext(:key))'),
                        {'key': 'identity:onboard:' + sha256(normalized.encode()).hexdigest()})
                now = current_proof_time()
                if self._user_by_phone(session, normalized) is not None:
                    raise AppError(code='INVITATION_TICKET_INVALID',
                        message='验证状态已失效，请重新获取验证码', status_code=401)
                try:
                    # Invalid invitation and registration failures must not
                    # leave an invitation use, user, or Outbox event behind.
                    with session.begin_nested():
                        user = self.registration.create_verified_phone_in_session(
                            session, phone=normalized, invitation_code=invitation_code, now=now)
                        if on_new_account is not None:
                            on_new_account()
                        OutboxPublisher.enqueue(session, topic='identity.matrix',
                            event_type='identity.matrix.provision.requested', aggregate_type='user',
                            aggregate_id=user.id, payload={'user_id': user.id}, now=now)
                except AppError as error:
                    if error.code not in ('INVITATION_REQUIRED', 'INVITATION_INVALID',
                                          'INVITATION_EXPIRED', 'INVITATION_EXHAUSTED'):
                        raise
                    proof.attempts_left -= 1
                    if proof.attempts_left <= 0:
                        proof.invalidated_at = now
                        result['exhausted'] = True
                    else:
                        result['correction'] = error.code
                else:
                    proof.purpose = 'login_resume'
                    proof.user_id = user.id
                    proof.attempts_left = 1
                    result['completed'] = True
            # Account creation and rate checks may wait after the row lock.
            # Abort the whole transaction if the proof expires before commit.
            current_proof_time()
        if result.get('exhausted'):
            raise AppError(code='INVITATION_TICKET_INVALID',
                message='验证状态已失效，请重新获取验证码', status_code=401)
        if result.get('correction'):
            return {'status': result['correction'], 'invitation_ticket': invitation_ticket}
        return {'status': 'PENDING_MATRIX', 'login_ticket': invitation_ticket,
                'retry_after_seconds': 2}

    def complete_login(self, *, login_ticket: str, device_key: str, device_name: str, tokens):
        """Single-use, device-bound proof. Never invokes the SMS verifier."""
        from app.modules.identity.models import OtpChallenge, User
        from app.modules.identity.enums import AccountStatus
        if not self.otp.phone_enabled:
            raise AppError(code="PHONE_AUTH_DISABLED", message="手机号功能未开启", status_code=503)
        now = self._utcnow()
        with self._factory.begin() as session:
            proof = session.scalar(select(OtpChallenge).where(
                OtpChallenge.purpose == 'login_resume',
                OtpChallenge.target == self._ticket_digest(login_ticket),
                OtpChallenge.registration_session == self._ticket_digest(device_key),
                OtpChallenge.consumed_at.is_(None), OtpChallenge.invalidated_at.is_(None),
                OtpChallenge.expires_at > now).with_for_update())
            if proof is None:
                raise AppError(code='LOGIN_TICKET_INVALID', message='登录凭据已失效，请重新登录', status_code=401)
            user = session.get(User, proof.user_id)
            if user is None or user.status not in (AccountStatus.PENDING_MATRIX, AccountStatus.ACTIVE):
                raise AppError(code='CREDENTIALS_INVALID', message='账号状态不可用', status_code=401)
            if not user.phone_verified_at or not user.phone_normalized or not hmac.compare_digest(
                    proof.code_hash, self._ticket_digest(user.phone_normalized)):
                raise AppError(code='LOGIN_TICKET_INVALID', message='登录凭据已失效，请重新登录', status_code=401)
            if user.status == AccountStatus.PENDING_MATRIX:
                return {'status': 'PENDING_MATRIX', 'retry_after_seconds': 2}
            consumed = session.execute(update(OtpChallenge).where(OtpChallenge.id == proof.id,
                OtpChallenge.consumed_at.is_(None)).values(consumed_at=now))
            if consumed.rowcount != 1:
                raise AppError(code='LOGIN_TICKET_INVALID', message='登录凭据已失效，请重新登录', status_code=401)
            user_id = user.id
        return tokens.issue_pair(user_id=user_id, device_key=device_key, display_name=device_name)

    # -------------------------------------------------------- 换绑
    def request_old_channel_verification(self, *, user_id: str) -> dict:
        """换绑第一步：验证"当前凭证"——已绑手机号一律验旧手机号 OTP；
        未绑手机的邮箱账户才走邮箱验证码（经 Outbox 由 worker 投递，
        明文不落库）。绝不把"有旧手机号"降级为邮箱验证。"""
        from app.core.outbox import OutboxPublisher
        from app.modules.identity.models import User

        with self._factory.begin() as session:
            user = session.get(User, user_id)
            if user is None:
                raise AppError(code="AUTH_REQUIRED", message="需要登录", status_code=401)
            if user.phone_normalized:
                self.otp.issue(purpose="phone_rebind_old", phone=user.phone_normalized, user_id=user_id)
                return {"channel": "phone", "target": mask_phone(user.phone_normalized)}
            if not user.email_normalized:
                raise AppError(code="REBIND_CHANNEL_UNAVAILABLE", message="账号缺少可验证的联系方式", status_code=409)
            otp_id = str(uuid4())
            from datetime import timedelta

            from app.modules.identity.models import OtpChallenge

            code = (self._email_code_deriver(otp_id) if self._email_code_deriver
                else f"{secrets.randbelow(1000000):06d}")

            session.add(OtpChallenge(id=otp_id, purpose="email_rebind_old", target=user.email_normalized,
                user_id=user_id, code_hash=_hash_code(code, self.otp._secret),
                expires_at=self._utcnow() + timedelta(seconds=OTP_TTL_SECONDS),
                attempts_left=OTP_MAX_ATTEMPTS, created_at=self._utcnow()))
            OutboxPublisher.enqueue(session, topic="identity.email",
                event_type="identity.email.otp.requested", aggregate_type="otp_challenge",
                aggregate_id=otp_id, payload={"otp_id": otp_id}, now=self._utcnow())
            return {"channel": "email", "target": user.email_normalized}

    def _has_recent_old_verification(self, session, user_id: str) -> bool:
        from app.modules.identity.models import OtpChallenge, User

        now = self._utcnow()
        user = session.get(User, user_id)
        if user is None:
            return False
        purpose = "phone_rebind_old" if user.phone_normalized else "email_rebind_old"
        target = user.phone_normalized or user.email_normalized
        row = session.scalar(select(OtpChallenge.id).where(
            OtpChallenge.user_id == user_id,
            OtpChallenge.purpose == purpose,
            OtpChallenge.target == target,
            OtpChallenge.invalidated_at.is_(None),
            OtpChallenge.consumed_at >= now - self.OLD_VERIF_WINDOW).limit(1))
        return row is not None

    def confirm_old_channel(self, *, user_id: str, code: str) -> dict:
        from app.modules.identity.models import User

        with self._factory() as session:
            user = session.get(User, user_id)
            if user is None:
                raise AppError(code="AUTH_REQUIRED", message="需要登录", status_code=401)
            purpose = "phone_rebind_old" if user.phone_normalized else "email_rebind_old"
            target = user.phone_normalized or user.email_normalized
        self.otp.verify_code(purpose=purpose, target=target, code=code, user_id=user_id)
        return {"verified": True}

    def request_new_phone_verification(self, *, user_id: str, new_phone: str) -> dict:
        """换绑第二步前提：旧凭证验证码已消费（5 分钟窗口内）。"""
        from app.modules.identity.models import User

        normalized = normalize_phone(new_phone)
        with self._factory.begin() as session:
            if not self._has_recent_old_verification(session, user_id):
                raise AppError(code="REBIND_OLD_VERIFICATION_REQUIRED", message="请先完成当前手机号/邮箱验证",
                    status_code=409)
            occupant = self._user_by_phone(session, normalized)
            if occupant is not None and occupant.id != user_id:
                raise AppError(code="PHONE_TAKEN", message="手机号已被使用", status_code=409)
        self.otp.issue(purpose="phone_rebind_new", phone=normalized, user_id=user_id)
        return {"status": "accepted"}

    def confirm_new_phone(self, *, user_id: str, new_phone: str, code: str) -> dict:
        """换绑完成：消费新号 OTP（单次）并原子换绑；两步顺序不可颠倒。"""
        from app.modules.identity.models import User

        normalized = normalize_phone(new_phone)
        now = self._utcnow()
        def complete(session, challenge):
            user = session.get(User, user_id, with_for_update=True)
            if user is None:
                raise AppError(code="AUTH_REQUIRED", message="需要登录", status_code=401)
            if not self._has_recent_old_verification(session, user_id):
                raise AppError(code="REBIND_OLD_VERIFICATION_REQUIRED", message="请先完成当前手机号/邮箱验证",
                    status_code=409)
            occupant = self._user_by_phone(session, normalized)
            if occupant is not None and occupant.id != user_id:
                raise AppError(code="PHONE_TAKEN", message="手机号已被使用", status_code=409)
            from app.modules.identity.models import OtpChallenge
            session.execute(update(OtpChallenge).where(OtpChallenge.user_id == user_id,
                OtpChallenge.purpose.in_(("phone_rebind_old", "email_rebind_old"))).values(invalidated_at=now))
            user.phone, user.phone_normalized = normalized, normalized
            user.phone_verified_at = now
            user.updated_at = now
        self.otp.verify_code(purpose="phone_rebind_new", target=normalized, code=code, user_id=user_id,
            on_verified=complete)
        return {"phone": mask_phone(normalized), "verified": True}

    # -------------------------------------------------------- 隐私搜索
    def search_by_phone(self, *, phone: str) -> dict:
        """完整号码精确匹配；不可找到/不存在/停用 → 同一空结果（防枚举）；
        响应绝不包含手机号。"""
        from app.modules.identity.enums import AccountStatus
        from app.modules.identity.models import User

        normalized = normalize_phone(phone)
        with self._factory() as session:
            user = self._user_by_phone(session, normalized)
            if user is None or user.status != AccountStatus.ACTIVE or not user.phone_findable:
                return {"found": False}
            return {"found": True, "user": {"user_id": user.id, "username": user.username,
                "nickname": user.nickname, "matrix_user_id": user.matrix_user_id}}
