"""ADR-0085 business credential proofs; Matrix credentials and keys are independent."""
from datetime import datetime, timedelta, timezone
from hashlib import sha256
import re
import secrets
from uuid import uuid4

from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError

from app.core.errors import AppError
from app.core.outbox import OutboxPublisher
from app.modules.audit.writer import AuditWriter
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import OtpChallenge, User
from app.modules.identity.phone import NullSmsSender, mask_phone, normalize_phone, check_verification_deadline
from app.modules.identity.recovery import invalidate_recovery_in_session

PASSWORD_PURPOSES = {'email': 'password_reset_email', 'phone': 'password_reset_phone'}
OLD_PURPOSES = ('email_bind_old_email', 'email_bind_old_phone')


def normalize_email(value: str) -> str:
    email = value.strip().casefold()
    if len(email) > 320 or not re.fullmatch(r'[^\s@<>(),;:]+@[^\s@<>(),;:]+\.[^\s@<>(),;:]+', email):
        raise AppError(code='EMAIL_INVALID', message='邮箱格式无效', status_code=422)
    return email


def mask_email(email: str | None) -> str:
    if not email:
        return ''
    local, domain = email.rsplit('@', 1)
    return local[:1] + '***@' + domain


def contact_snapshot(user, channel):
    verified = getattr(user, channel + '_verified_at')
    if verified is None:
        return None
    verified = verified.replace(tzinfo=timezone.utc) if verified.tzinfo is None else verified.astimezone(timezone.utc)
    value = f'{channel}:{getattr(user, channel + "_normalized")}:{verified.isoformat()}'
    return sha256(value.encode()).hexdigest()


class AccountCredentialsService:
    def __init__(self, session_factory, *, otp, recovery, email_code_deriver, now_factory=None):
        self._factory = session_factory
        self.otp = otp
        self.recovery = recovery
        self._email_code_deriver = email_code_deriver
        self._now = now_factory or (lambda: datetime.now(timezone.utc))

    def now(self):
        value = self._now()
        return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)

    @staticmethod
    def _invalid():
        raise AppError(code='PASSWORD_RESET_INVALID', message='验证信息无效或已过期', status_code=400)

    @staticmethod
    def _target(channel, target):
        if channel not in PASSWORD_PURPOSES:
            raise AppError(code='OTP_CHANNEL_INVALID', message='验证方式无效', status_code=422)
        return normalize_email(target) if channel == 'email' else normalize_phone(target)

    @staticmethod
    def _matches(user, channel, target):
        return bool(user and user.status == AccountStatus.ACTIVE and
            getattr(user, channel + '_normalized') == target and getattr(user, channel + '_verified_at') is not None)

    def _owner(self, session, channel, target, user_id=None):
        user = session.scalar(select(User).where(getattr(User, channel + '_normalized') == target))
        return user if self._matches(user, channel, target) and (user_id is None or user.id == user_id) else None

    def _require_target(self, session, owner, channel, target):
        user = session.scalar(select(User).where(User.id == owner).with_for_update())
        if not self._matches(user, channel, target):
            self._invalid()
        return user

    def request_password_code(self, *, channel, target, user_id=None):
        target = self._target(channel, target)
        accepted = {'accepted': True, 'resend_after_seconds': 60}
        if channel == 'phone':
            if not self.otp.phone_enabled:
                raise AppError(code='PHONE_AUTH_DISABLED', message='手机号功能未开启', status_code=503)
            if isinstance(self.otp.sender, NullSmsSender):
                raise AppError(code='SMS_NOT_CONFIGURED', message='短信服务未配置', status_code=503)
        with self._factory() as session:
            user = self._owner(session, channel, target, user_id)
            if user is None:
                return accepted
            owner = user.id
            snapshot = contact_snapshot(user, channel)
        def check(session):
            user = self._require_target(session, owner, channel, target)
            if contact_snapshot(user, channel) != snapshot:
                self._invalid()
        try:
            if channel == 'email':
                self.otp.issue_email(purpose=PASSWORD_PURPOSES[channel], target=target, user_id=owner,
                    code_deriver=self._email_code_deriver, registration_session=snapshot, on_issue=check)
            else:
                self.otp.issue_password_phone(target=target, user_id=owner, registration_session=snapshot,
                    code_deriver=self._email_code_deriver, on_issue=check)
        except AppError as error:
            if user_id is not None and error.code != 'PASSWORD_RESET_INVALID':
                raise
            # Public acceptance is identical for unknown targets, quota and provider failures.
        except Exception:
            if user_id is not None:
                raise AppError(code='OTP_DELIVERY_UNAVAILABLE', message='验证请求暂不可用', status_code=503) from None
        return accepted

    def verify_password_code(self, *, channel, target, code, user_id=None, deadline=None):
        target = self._target(channel, target)
        with self._factory() as session:
            check_verification_deadline(deadline, session)
            user = self._owner(session, channel, target, user_id)
            check_verification_deadline(deadline)
            if user is None:
                self._invalid()
            owner = user.id
        token = secrets.token_urlsafe(48)
        def complete(session, challenge):
            check_verification_deadline(deadline, session)
            user = self._require_target(session, owner, channel, target)
            snapshot = contact_snapshot(user, channel)
            if challenge.registration_session != snapshot:
                self._invalid()
            session.execute(update(OtpChallenge).where(OtpChallenge.user_id == owner,
                OtpChallenge.purpose == 'password_reset_grant', OtpChallenge.consumed_at.is_(None)).values(invalidated_at=self.now()))
            session.add(OtpChallenge(id=str(uuid4()), purpose='password_reset_grant', target=target,
                user_id=owner, registration_session=snapshot, code_hash=sha256(token.encode()).hexdigest(),
                expires_at=self.now() + timedelta(minutes=5), attempts_left=1, created_at=self.now()))
        try:
            self.otp.verify_code(purpose=PASSWORD_PURPOSES[channel], target=target, code=code,
                user_id=owner, on_verified=complete, deadline=deadline)
        except AppError as error:
            if error.code == 'OTP_INVALID' or user_id is None:
                self._invalid()
            raise
        except Exception:
            if user_id is None:
                self._invalid()
            raise AppError(code='OTP_VERIFICATION_UNAVAILABLE', message='验证请求暂不可用', status_code=503) from None
        return {'reset_token': token, 'expires_in': 300}

    def reset_password(self, *, token, new_password, user_id=None, trace_id='unknown', source_ip=None):
        if not isinstance(new_password, str) or not 12 <= len(new_password) <= 256:
            raise AppError(code='PASSWORD_INVALID', message='密码须为12至256位', status_code=422)
        digest, now = sha256(token.encode()).hexdigest(), self.now()
        with self._factory.begin() as session:
            owner = session.scalar(select(OtpChallenge.user_id).where(OtpChallenge.purpose == 'password_reset_grant', OtpChallenge.code_hash == digest))
            if owner is None or (user_id is not None and user_id != owner):
                self._invalid()
            user = session.scalar(select(User).where(User.id == owner).with_for_update())
            grant = session.scalar(select(OtpChallenge).where(OtpChallenge.purpose == 'password_reset_grant',
                OtpChallenge.code_hash == digest, OtpChallenge.consumed_at.is_(None),
                OtpChallenge.invalidated_at.is_(None), OtpChallenge.expires_at > now).with_for_update())
            now = self.now()
            channel = 'email' if grant and '@' in grant.target else 'phone'
            if grant is None or self._utc(grant.expires_at) <= now or not self._matches(user, channel, grant.target) or grant.registration_session != contact_snapshot(user, channel):
                self._invalid()
            claimed = session.execute(update(OtpChallenge).where(OtpChallenge.id == grant.id,
                OtpChallenge.consumed_at.is_(None), OtpChallenge.invalidated_at.is_(None), OtpChallenge.expires_at > now)
                .values(consumed_at=now).execution_options(synchronize_session=False))
            if claimed.rowcount != 1:
                self._invalid()
            self.recovery.reset_in_session(session, user, new_password, trace_id=trace_id, source_ip=source_ip)

    def _active_user(self, session, user_id, *, lock=False):
        user = session.scalar(select(User).where(User.id == user_id).with_for_update()) if lock else session.get(User, user_id)
        if user is None or user.status != AccountStatus.ACTIVE:
            raise AppError(code='AUTH_REQUIRED', message='需要登录', status_code=401)
        return user

    def summary(self, user_id):
        with self._factory() as session:
            user = self._active_user(session, user_id)
            return {'masked_email': mask_email(user.email_normalized), 'masked_phone': mask_phone(user.phone_normalized) if user.phone_normalized else '',
                'email_bound': bool(user.email_normalized), 'phone_bound': bool(user.phone_normalized),
                'email_verified': bool(user.email_normalized and user.email_verified_at),
                'phone_verified': bool(user.phone_normalized and user.phone_verified_at)}

    def _email_delivery_current(self, session, user, challenge):
        if user is None or user.status != AccountStatus.ACTIVE:
            return False
        if challenge.purpose in ('password_reset_email', 'email_bind_old_email'):
            return bool(self._matches(user, 'email', challenge.target)
                and challenge.registration_session == contact_snapshot(user, 'email'))
        if challenge.purpose == 'email_bind_new':
            try:
                return self._old_proof(session, user).id == challenge.registration_session
            except AppError:
                return False
        return False

    def claim_email_delivery(self, challenge_id):
        """Worker application operation: claim one send intent before contacting SMTP."""
        with self._factory.begin() as session:
            owner = session.scalar(select(OtpChallenge.user_id).where(OtpChallenge.id == challenge_id))
            user = session.scalar(select(User).where(User.id == owner).with_for_update())
            challenge = session.get(OtpChallenge, challenge_id, with_for_update=True)
            if (challenge is None or challenge.purpose not in ('password_reset_email', 'email_bind_old_email', 'email_bind_new')
                    or challenge.attempts_left != 0 or challenge.invalidated_at is not None or challenge.consumed_at is not None
                    or self._utc(challenge.expires_at) <= self.now()
                    or not self._email_delivery_current(session, user, challenge)):
                return None
            challenge.attempts_left = -1
            return challenge.target

    @staticmethod
    def _utc(value):
        return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)

    def finish_email_delivery(self, challenge_id, *, delivered):
        """A late/failed delivery never grants proof verification rights."""
        with self._factory.begin() as session:
            owner = session.scalar(select(OtpChallenge.user_id).where(OtpChallenge.id == challenge_id))
            user = session.scalar(select(User).where(User.id == owner).with_for_update())
            challenge = session.get(OtpChallenge, challenge_id, with_for_update=True)
            if challenge is None:
                return
            if (delivered and challenge.attempts_left == -1 and challenge.invalidated_at is None
                    and challenge.consumed_at is None and self._utc(challenge.expires_at) > self.now()
                    and self._email_delivery_current(session, user, challenge)):
                challenge.attempts_left = 5
            else:
                challenge.attempts_left = 0
                challenge.invalidated_at = self.now()

    @staticmethod
    def _old_channel(user):
        if user.email_normalized and user.email_verified_at:
            return 'email', user.email_normalized, 'email_bind_old_email'
        if not user.email_normalized and user.phone_normalized and user.phone_verified_at:
            return 'phone', user.phone_normalized, 'email_bind_old_phone'
        raise AppError(code='REBIND_CHANNEL_UNAVAILABLE', message='账号缺少可验证的联系方式', status_code=409)

    def request_old_email_channel(self, *, user_id):
        with self._factory() as session:
            user = self._active_user(session, user_id)
            channel, target, purpose = self._old_channel(user)
            snapshot = contact_snapshot(user, channel)
        def check(session):
            user = self._active_user(session, user_id, lock=True)
            if self._old_channel(user) != (channel, target, purpose) or contact_snapshot(user, channel) != snapshot:
                raise AppError(code='REBIND_OLD_VERIFICATION_REQUIRED', message='请重新验证原联系方式', status_code=409)
        if channel == 'email':
            self.otp.issue_email(purpose=purpose, target=target, user_id=user_id, code_deriver=self._email_code_deriver, registration_session=snapshot, on_issue=check)
        else:
            self.otp.issue(purpose=purpose, phone=target, user_id=user_id, registration_session=snapshot, on_issue=check)
        return {'channel': channel, 'target': mask_email(target) if channel == 'email' else mask_phone(target)}

    def confirm_old_email_channel(self, *, user_id, code):
        with self._factory() as session:
            channel, target, purpose = self._old_channel(self._active_user(session, user_id))
        def check(session, challenge):
            user = self._active_user(session, user_id, lock=True)
            if self._old_channel(user) != (channel, target, purpose) or challenge.registration_session != contact_snapshot(user, channel):
                raise AppError(code='REBIND_OLD_VERIFICATION_REQUIRED', message='请重新验证原联系方式', status_code=409)
            # The consumed OTP becomes an ownership proof, whose five-minute
            # lifetime begins at successful verification rather than issuance.
            challenge.expires_at = self.now() + timedelta(minutes=5)
        self.otp.verify_code(purpose=purpose, target=target, code=code, user_id=user_id, on_verified=check)
        return {'verified': True}

    def _old_proof(self, session, user):
        channel, target, purpose = self._old_channel(user)
        proof = session.scalar(select(OtpChallenge).where(OtpChallenge.user_id == user.id,
            OtpChallenge.purpose == purpose, OtpChallenge.target == target, OtpChallenge.invalidated_at.is_(None),
            OtpChallenge.registration_session == contact_snapshot(user, channel),
            OtpChallenge.consumed_at > self.now() - timedelta(minutes=5), OtpChallenge.expires_at > self.now())
            .order_by(OtpChallenge.created_at.desc()).with_for_update())
        if proof is None:
            raise AppError(code='REBIND_OLD_VERIFICATION_REQUIRED', message='请先验证原联系方式', status_code=409)
        return proof

    @staticmethod
    def _email_available(session, target, user_id):
        if session.scalar(select(User.id).where(User.email_normalized == target, User.id != user_id)):
            raise AppError(code='EMAIL_TAKEN', message='邮箱已被使用', status_code=409)

    def request_new_email(self, *, user_id, email):
        target = normalize_email(email)
        with self._factory.begin() as session:
            proof_id = self._old_proof(session, self._active_user(session, user_id, lock=True)).id
        def check(session):
            user = self._active_user(session, user_id, lock=True)
            if self._old_proof(session, user).id != proof_id:
                raise AppError(code='REBIND_OLD_VERIFICATION_REQUIRED', message='请重新验证原联系方式', status_code=409)
            if user.email_normalized == target:
                raise AppError(code='EMAIL_UNCHANGED', message='请输入新的邮箱', status_code=409)
            self._email_available(session, target, user_id)
        self.otp.issue_email(purpose='email_bind_new', target=target, user_id=user_id,
            code_deriver=self._email_code_deriver, registration_session=proof_id, on_issue=check)
        return {'accepted': True}

    def confirm_new_email(self, *, user_id, new_email, code, trace_id='unknown', source_ip=None):
        target, now = normalize_email(new_email), self.now()
        def complete(session, challenge):
            user = self._active_user(session, user_id, lock=True)
            old = self._old_proof(session, user)
            if challenge.registration_session != old.id:
                raise AppError(code='REBIND_OLD_VERIFICATION_REQUIRED', message='请重新验证原联系方式', status_code=409)
            self._email_available(session, target, user_id)
            old.invalidated_at = now
            session.execute(update(OtpChallenge).where(OtpChallenge.user_id == user_id,
                OtpChallenge.purpose.in_((*OLD_PURPOSES, 'email_bind_new'))).values(invalidated_at=now))
            user.email = user.email_normalized = target
            user.email_verified_at = user.updated_at = now
            invalidate_recovery_in_session(session, user_id, now)
            AuditWriter(self._factory, now_factory=self._now).record_in_session(session,
                actor_id=user_id, subject_type='user', subject_id=user_id, action='identity.email.bound',
                result='SUCCESS', reason_code='EMAIL_BINDING', trace_id=trace_id, source_ip=source_ip)
            OutboxPublisher.enqueue(session, topic='identity.account_credentials', event_type='identity.email.bound',
                aggregate_type='user', aggregate_id=user_id, payload={'user_id': user_id, 'reason_code': 'EMAIL_BINDING'}, now=now)
        try:
            self.otp.verify_code(purpose='email_bind_new', target=target, code=code, user_id=user_id, on_verified=complete)
        except IntegrityError:
            raise AppError(code='EMAIL_TAKEN', message='邮箱已被使用', status_code=409) from None
        return {'email': mask_email(target), 'verified': True}
