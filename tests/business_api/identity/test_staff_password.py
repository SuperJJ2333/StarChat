from datetime import timedelta, timezone

import pytest
from sqlalchemy import event, select
from sqlalchemy.orm import Session

from app.core.errors import AppError
from app.core.outbox import OutboxEvent
from app.modules.audit.models import AuditEvent
from app.modules.identity.enums import RoleCode
from app.modules.identity.models import AdminSession, OtpChallenge, PasswordResetChallenge, RefreshTokenFamily, SecurityHold, User, UserRole
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.phone import PhoneOtpService
from app.modules.identity.recovery import PasswordRecoveryService, PasswordResetTokenCodec
from app.modules.identity.tokens import TokenService
pytest_plugins = ('tests.business_api.identity.test_staff_activation',)


@pytest.mark.parametrize('staff_role', [RoleCode.SUPPORT_AGENT, RoleCode.FINANCE_SUPPORT,
    RoleCode.SUPPORT_SUPERVISOR])
def test_activated_staff_changes_shared_password_and_revokes_all_proofs(env, staff_role):
    from app.modules.identity.staff_password import StaffPasswordService

    factory, clock, sender, activation = env
    with factory.begin() as session:
        session.get(UserRole, 'role').role_code = staff_role
        user = session.get(User, 'staff')
        user.email = 'staff@example.invalid'
        user.email_normalized = 'staff@example.invalid'
        user.email_verified_at = clock[0]
    challenge = activation.request(username='staff', password='correct password 123')
    activation.confirm(activation_id=challenge['activation_id'], code=sender.messages[-1][1])
    tokens = TokenService(factory, jwt_secret='test-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer='liuhetong', now_factory=lambda: clock[0])
    mobile = tokens.issue_pair(user_id='staff', device_key='mobile', display_name='Mobile')
    admin = tokens.issue_admin_pair(user_id='staff', display_name='Staff browser', staff_only=True)
    recovery = PasswordRecoveryService(factory, password_hasher=PasswordHasher(),
        token_codec=PasswordResetTokenCodec(b'test-password-reset-secret'), now_factory=lambda: clock[0])
    old_link = recovery.request('staff@example.invalid')

    StaffPasswordService(factory, tokens=tokens, recovery=recovery, now_factory=lambda: clock[0]).change(
        access_token=admin.access_token, refresh_cookie=admin.refresh_token,
        current_password='correct password 123', new_password='new correct password 456',
        trace_id='staff-password-test', source_ip='127.0.0.1')

    with factory() as session:
        assert PasswordHasher().verify(session.get(User, 'staff').password_hash, 'new correct password 456')
        assert all(row.revoked_at is not None for row in session.scalars(
            select(RefreshTokenFamily).where(RefreshTokenFamily.user_id == 'staff')))
        hold = session.scalar(select(SecurityHold).where(SecurityHold.user_id == 'staff'))
        assert hold.reason_code == 'PASSWORD_RESET'
        assert hold.ends_at.replace(tzinfo=timezone.utc) - hold.starts_at.replace(tzinfo=timezone.utc) == timedelta(hours=24)
        assert all(row.consumed_at is not None for row in session.scalars(
            select(PasswordResetChallenge).where(PasswordResetChallenge.user_id == 'staff')))
        audit = session.scalar(select(AuditEvent).where(AuditEvent.action == 'identity.password.reset'))
        events = list(session.scalars(select(OutboxEvent).where(OutboxEvent.event_type == 'identity.password.reset')))
        assert audit.actor_id == 'staff'
        assert audit.reason_code == 'PASSWORD_RESET'
        assert len(events) == 1
        assert events[0].aggregate_id == 'staff'
        assert events[0].topic == 'identity.account_credentials'
        assert events[0].payload == {'user_id': 'staff', 'reason_code': 'PASSWORD_RESET'}
    for action in (lambda: tokens.decode_access_token(admin.access_token),
                   lambda: tokens.rotate(mobile.refresh_token),
                   lambda: recovery.reset(old_link, 'another secure password 789')):
        with pytest.raises(AppError):
            action()


@pytest.mark.parametrize('state', ['wrong_password', 'revoked_role', 'super_admin', 'unactivated', 'app_bearer'])
def test_staff_password_rejects_ineligible_actor(env, state):
    from app.modules.identity.staff_password import StaffPasswordService

    factory, clock, sender, activation = env
    if state != 'unactivated':
        challenge = activation.request(username='staff', password='correct password 123')
        activation.confirm(activation_id=challenge['activation_id'], code=sender.messages[-1][1])
    tokens = TokenService(factory, jwt_secret='test-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer='liuhetong', now_factory=lambda: clock[0])
    admin = tokens.issue_admin_pair(user_id='staff', display_name='Staff browser', staff_only=True) if state != 'unactivated' else None
    if state == 'unactivated':
        mobile = tokens.issue_pair(user_id='staff', device_key='mobile', display_name='Mobile')
    if state == 'app_bearer':
        mobile = tokens.issue_pair(user_id='staff', device_key='mobile', display_name='Mobile')
    with factory.begin() as session:
        if state == 'revoked_role':
            session.delete(session.get(UserRole, 'role'))
        if state == 'super_admin':
            session.add(UserRole(id='super', user_id='staff', role_code=RoleCode.SUPER_ADMIN,
                assigned_by='admin', assigned_at=clock[0]))
    recovery = PasswordRecoveryService(factory, password_hasher=PasswordHasher(),
        token_codec=PasswordResetTokenCodec(b'test-password-reset-secret'), now_factory=lambda: clock[0])
    with pytest.raises(AppError):
        StaffPasswordService(factory, tokens=tokens, recovery=recovery, now_factory=lambda: clock[0]).change(
            access_token=mobile.access_token if state in ('app_bearer', 'unactivated') else admin.access_token,
            refresh_cookie=admin.refresh_token if admin else '',
            current_password='wrong' if state == 'wrong_password' else 'correct password 123',
            new_password='new correct password 456', trace_id='staff-password-test')
    with factory() as session:
        assert PasswordHasher().verify(session.get(User, 'staff').password_hash, 'correct password 123')


def test_admin_entry_cannot_change_staff_password_after_role_demoted_between_checks(env, monkeypatch):
    from app.modules.identity.staff_password import StaffPasswordService

    factory, clock, sender, activation = env
    challenge = activation.request(username='staff', password='correct password 123')
    activation.confirm(activation_id=challenge['activation_id'], code=sender.messages[-1][1])
    with factory.begin() as session:
        session.add(UserRole(id='temporary-admin', user_id='staff', role_code=RoleCode.SUPER_ADMIN,
            assigned_by='external-admin', assigned_at=clock[0]))
    tokens = TokenService(factory, jwt_secret='test-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer='liuhetong', now_factory=lambda: clock[0])
    pair = tokens.issue_admin_pair(user_id='staff', display_name='Admin browser', admin_only=True)
    with factory() as session:
        assert session.get(AdminSession, 'staff').entry_mode == 'ADMIN'
    recovery = PasswordRecoveryService(factory, password_hasher=PasswordHasher(),
        token_codec=PasswordResetTokenCodec(b'test-password-reset-secret'), now_factory=lambda: clock[0])
    verify_cookie = tokens.require_admin_cookie

    def demote_after_outer_check(access_token, refresh_cookie):
        verify_cookie(access_token, refresh_cookie)
        with factory.begin() as session:
            session.delete(session.get(UserRole, 'temporary-admin'))

    monkeypatch.setattr(tokens, 'require_admin_cookie', demote_after_outer_check)
    with pytest.raises(AppError) as error:
        StaffPasswordService(factory, tokens=tokens, recovery=recovery,
            now_factory=lambda: clock[0]).change(
                access_token=pair.access_token, refresh_cookie=pair.refresh_token,
                current_password='correct password 123', new_password='new correct password 456',
                trace_id='admin-entry-demoted')
    assert error.value.code == 'ADMIN_SESSION_REPLACED'
    with factory() as session:
        assert PasswordHasher().verify(session.get(User, 'staff').password_hash,
            'correct password 123')
        assert session.scalar(select(AuditEvent).where(
            AuditEvent.action == 'identity.password.reset')) is None
        assert session.scalar(select(OutboxEvent).where(
            OutboxEvent.event_type == 'identity.password.reset')) is None


def test_admin_access_checks_lock_user_before_staff_roles(env):
    factory, clock, sender, activation = env
    challenge = activation.request(username='staff', password='correct password 123')
    activation.confirm(activation_id=challenge['activation_id'], code=sender.messages[-1][1])
    tokens = TokenService(factory, jwt_secret='test-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer='liuhetong', now_factory=lambda: clock[0])
    pair = tokens.issue_admin_pair(user_id='staff', display_name='Staff browser', staff_only=True)
    observations = []

    def capture(execution):
        statement = execution.statement
        descriptions = getattr(statement, 'column_descriptions', ())
        for description in descriptions:
            if description.get('entity') in (User, UserRole):
                observations.append((description['entity'], statement._for_update_arg is not None))
                break

    event.listen(Session, 'do_orm_execute', capture)
    try:
        tokens.decode_access_token(pair.access_token)
    finally:
        event.remove(Session, 'do_orm_execute', capture)
    first_user = next(i for i, (entity, _) in enumerate(observations) if entity is User)
    first_role = next(i for i, (entity, _) in enumerate(observations) if entity is UserRole)
    assert first_user < first_role
    assert observations[first_user][1] is True


def test_user_bound_otp_rechecks_expiry_after_user_lock(env):
    factory, clock, sender, _ = env
    otp = PhoneOtpService(factory, sender=sender, secret='otp-expiry-test', now=lambda: clock[0])
    otp.issue(purpose='staff_activation_phone', phone='+8613800000000', user_id='staff')
    submitted_at = clock[0]
    after_lock = submitted_at + timedelta(seconds=900)
    read_times = [submitted_at, after_lock]

    def advancing_clock():
        return read_times.pop(0) if read_times else after_lock

    verifier = PhoneOtpService(factory, sender=sender, secret='otp-expiry-test', now=advancing_clock)
    with pytest.raises(AppError) as error:
        verifier.verify_code(purpose='staff_activation_phone', target='+8613800000000',
            code=sender.messages[-1][1], user_id='staff')
    assert error.value.code == 'OTP_INVALID'
    with factory() as session:
        assert session.scalar(select(OtpChallenge)).consumed_at is None
