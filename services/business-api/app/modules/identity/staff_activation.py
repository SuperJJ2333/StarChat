"""Purpose-bound activation of existing official staff. Never assigns a role."""
from datetime import datetime, timedelta, timezone
from hashlib import sha256
import json
import secrets

from sqlalchemy import DateTime, ForeignKey, String, select
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base
from app.core.errors import AppError
from app.core.outbox import OutboxPublisher
from app.modules.audit.writer import AuditWriter
from app.modules.identity.enums import AccountStatus, RoleCode
from app.modules.identity.models import User, UserRole, OtpChallenge
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.phone import PhoneOtpService, SmsSender, mask_phone

STAFF_ROLES = (RoleCode.SUPPORT_AGENT, RoleCode.FINANCE_SUPPORT, RoleCode.SUPPORT_SUPERVISOR)


class StaffActivationChallenge(Base):
    __tablename__ = 'identity_staff_activation_challenges'
    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    user_id: Mapped[str] = mapped_column(ForeignKey('users.id'), nullable=False, index=True)
    identity_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    channel: Mapped[str] = mapped_column(String(8), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    consumed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class StaffActivation(Base):
    __tablename__ = 'identity_staff_activations'
    user_id: Mapped[str] = mapped_column(ForeignKey('users.id'), primary_key=True)
    identity_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    activated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


def utc(value):
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def denied(code='STAFF_ACTIVATION_INVALID', status=403):
    raise AppError(code=code, message='客服身份或验证状态无效，请核对账号后重试', status_code=status)


def staff_identity(session, user, channel=None):
    if user is None or user.status != AccountStatus.ACTIVE:
        denied()
    roles = session.scalars(select(UserRole).where(UserRole.user_id == user.id,
        UserRole.role_code.in_(STAFF_ROLES)).order_by(UserRole.id).with_for_update()
        .execution_options(populate_existing=True)).all()
    if not roles:
        denied()
    if channel not in (None, 'phone', 'email'):
        denied('STAFF_CONTACT_UNVERIFIED')
    if channel == 'phone' or (channel is None and user.phone_normalized):
        if not user.phone_normalized or not user.phone_verified_at:
            denied('STAFF_CONTACT_UNVERIFIED')
        channel, target, verified = 'phone', user.phone_normalized, user.phone_verified_at
    elif user.email_normalized and user.email_verified_at:
        channel, target, verified = 'email', user.email_normalized, user.email_verified_at
    else:
        denied('STAFF_CONTACT_UNVERIFIED')
    snapshot = [user.id, channel, target, utc(verified).isoformat(),
        [[role.id, role.role_code.value, utc(role.assigned_at).isoformat()] for role in roles]]
    return channel, target, sha256(json.dumps(snapshot, separators=(',', ':')).encode()).hexdigest()


def require_staff_admin_access(session, user, *, staff_only=False):
    """Existing super administrators remain compatible; staff cannot skip activation."""
    is_superadmin = session.scalar(select(UserRole.id).where(UserRole.user_id == user.id,
        UserRole.role_code == RoleCode.SUPER_ADMIN)) is not None
    if staff_only and is_superadmin:
        # A mixed-role account still receives full admin permissions from RBAC;
        # it must use the administrator entry point with CAPTCHA.
        denied()
    if staff_only and not session.scalar(select(UserRole.id).where(UserRole.user_id == user.id,
            UserRole.role_code.in_((RoleCode.SUPPORT_AGENT, RoleCode.FINANCE_SUPPORT)))):
        denied()
    if not staff_only and is_superadmin:
        return
    active = session.get(StaffActivation, user.id, populate_existing=True)
    # The digest already includes its channel. Match verified contacts explicitly
    # to preserve old phone-first records without adding a nullable schema field.
    for channel in ('phone', 'email'):
        try:
            _, _, digest = staff_identity(session, user, channel)
        except AppError:
            continue
        if active is not None and active.identity_digest == digest:
            return
    raise AppError(code='STAFF_ACTIVATION_REQUIRED', message='请先完成客服后台首次开通', status_code=403)


class _EmailSender(SmsSender):
    def __init__(self, factory, now):
        self.factory, self.now = factory, now

    def send_challenge(self, phone, code, purpose, challenge_id):
        # Shared worker derives the code from ID. Only the opaque ID enters Outbox.
        with self.factory.begin() as session:
            require_pending_delivery(session, challenge_id, self.now())
            OutboxPublisher.enqueue(session, topic='identity.email',
                event_type='identity.email.otp.requested', aggregate_type='otp_challenge',
                aggregate_id=challenge_id, payload={'otp_id': challenge_id}, now=self.now())


def require_pending_delivery(session, challenge_id, now):
    otp = session.get(OtpChallenge, challenge_id)
    challenge = session.get(StaffActivationChallenge, otp.registration_session) if otp else None
    if (challenge is None or challenge.consumed_at or utc(challenge.expires_at) <= utc(now)
            or otp.invalidated_at or otp.consumed_at):
        denied()
    _, _, digest = staff_identity(session, session.get(User, challenge.user_id), challenge.channel)
    if challenge.identity_digest != digest:
        denied()


class _BoundPhoneSender(SmsSender):
    def __init__(self, factory, sender, now):
        self.factory, self.sender, self.now = factory, sender, now

    def send_challenge(self, phone, code, purpose, challenge_id):
        with self.factory() as session:
            require_pending_delivery(session, challenge_id, self.now())
        self.sender.send_challenge(phone, code, purpose, challenge_id)


class StaffActivationService:
    def __init__(self, session_factory, *, phone_otp, email_code_deriver, now=None):
        self.factory = session_factory
        self.now = now or (lambda: datetime.now(timezone.utc))
        self.phone_otp = PhoneOtpService(session_factory,
            sender=_BoundPhoneSender(session_factory, phone_otp.sender, self.now),
            secret=phone_otp._secret, now=self.now, phone_enabled=phone_otp.phone_enabled,
            code_verifier=phone_otp.code_verifier)
        self.email_otp = PhoneOtpService(session_factory, sender=_EmailSender(session_factory, self.now),
            secret=phone_otp._secret, now=self.now, code_deriver=email_code_deriver)
        self.audit = AuditWriter(session_factory, now_factory=self.now)

    def request(self, *, username, password, channel=None):
        normalized = username.strip().casefold()
        now = utc(self.now())
        activation_id = secrets.token_urlsafe(32)
        with self.factory.begin() as session:
            user = session.scalar(select(User).where(User.email_normalized == normalized
                if '@' in normalized else User.username_normalized == normalized).with_for_update())
            if user is None or user.status != AccountStatus.ACTIVE or not PasswordHasher().verify(user.password_hash, password):
                denied('CREDENTIALS_INVALID', 401)
            channel, target, digest = staff_identity(session, user, channel)
            existing = session.get(StaffActivation, user.id)
            if existing is not None and existing.identity_digest == digest:
                denied('STAFF_ALREADY_ACTIVATED', 409)
            session.add(StaffActivationChallenge(id=activation_id, user_id=user.id,
                identity_digest=digest, channel=channel, expires_at=now + timedelta(seconds=300)))
            user_id = user.id
        otp = self.phone_otp if channel == 'phone' else self.email_otp
        otp.issue(purpose='staff_activation_' + channel, phone=target,
            user_id=user_id, registration_session=activation_id)
        masked = mask_phone(target) if channel == 'phone' else target[:1] + '***@' + target.split('@')[-1]
        return {'activation_id': activation_id, 'channel': channel, 'masked_target': masked, 'expires_in': 300}

    def confirm(self, *, activation_id, code):
        now = utc(self.now())
        with self.factory() as session:
            challenge = session.get(StaffActivationChallenge, activation_id)
            if challenge is None or challenge.consumed_at or utc(challenge.expires_at) <= now:
                denied()
            user_id = challenge.user_id
            channel, target, digest = staff_identity(session, session.get(User, user_id), challenge.channel)
            if challenge.identity_digest != digest or challenge.channel != channel:
                denied()

        def complete(session, otp_row):
            user = session.get(User, user_id, with_for_update=True)
            _, _, current_digest = staff_identity(session, user, channel)
            challenge = session.get(StaffActivationChallenge, activation_id, with_for_update=True)
            if (challenge is None or challenge.consumed_at or utc(challenge.expires_at) <= utc(self.now())
                    or current_digest != digest or challenge.identity_digest != current_digest):
                denied()
            active = session.get(StaffActivation, user_id)
            if active is None:
                session.add(StaffActivation(user_id=user_id, identity_digest=digest, activated_at=now))
            else:
                active.identity_digest, active.activated_at = digest, now
            challenge.consumed_at = now
            self.audit.record_in_session(session, actor_id=user_id, subject_type='user', subject_id=user_id,
                action='identity.staff.activated', result='SUCCESS', reason_code='STAFF_BOUND_CONTACT_ACTIVATION',
                trace_id=activation_id)
            OutboxPublisher.enqueue(session, topic='identity.staff', event_type='identity.staff.activated',
                aggregate_type='user', aggregate_id=user_id, payload={'user_id': user_id}, now=now)

        otp = self.phone_otp if channel == 'phone' else self.email_otp
        otp.verify_code(purpose='staff_activation_' + channel, target=target, code=code,
            user_id=user_id, registration_session=activation_id, on_verified=complete)
        return {'status': 'activated', 'user_id': user_id}
