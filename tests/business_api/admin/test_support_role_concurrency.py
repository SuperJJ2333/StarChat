"""Isolated PostgreSQL races for staff password and support role changes."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from threading import Barrier, Event
from uuid import uuid4
import os
import importlib

import pytest
from sqlalchemy import create_engine, select, text
from sqlalchemy.engine import make_url

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.core.outbox import OutboxEvent
from app.modules.admin.service import AdminControlService
from app.modules.audit.models import AuditEvent
from app.modules.identity.enums import AccountStatus, RoleCode
from app.modules.identity.models import OtpChallenge, SecurityHold, User, UserRole
from app.modules.identity.account_credentials import AccountCredentialsService, contact_snapshot
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.phone import PhoneOtpService, RecordingSmsSender
from app.modules.identity.recovery import PasswordRecoveryService, PasswordResetTokenCodec
from app.modules.identity.staff_activation import StaffActivation, StaffActivationService
from app.modules.identity.staff_password import StaffPasswordService
from app.modules.identity.tokens import TokenService


@pytest.fixture
def components():
    raw = os.environ.get('STAFF_PASSWORD_TEST_DATABASE_URL')
    if not raw:
        pytest.skip('dedicated local PostgreSQL URL not supplied')
    url = make_url(raw)
    if url.host not in ('localhost', '127.0.0.1') or url.database in ('postgres', 'template0', 'template1'):
        raise RuntimeError('staff password race tests require a dedicated local PostgreSQL database')
    schema = 'staff_password_' + uuid4().hex
    admin_engine = create_engine(url)
    with admin_engine.begin() as connection:
        connection.execute(text(f'CREATE SCHEMA "{schema}"'))
    test_url = url.update_query_dict({'options': f'-csearch_path={schema} -cstatement_timeout=15000'})
    engine = create_engine(test_url, pool_size=5)
    try:
        with engine.connect() as connection:
            assert connection.scalar(text('SELECT current_schema()')) == schema
        importlib.import_module('app.main')  # Register all mapped models before schema creation.
        # This identity race fixture needs identity, administration, support,
        # audit and Outbox tables.
        # Unrelated financial models use migration-specific PostgreSQL DDL;
        # creating their SQLite-oriented metadata here masks the race itself.
        tables = {mapper.local_table for mapper in Base.registry.mappers
                  if mapper.class_.__module__.startswith(('app.modules.identity', 'app.modules.admin', 'app.modules.support'))}
        tables.update((AuditEvent.__table__, OutboxEvent.__table__))
        pending = list(tables)
        while pending:
            for foreign_key in pending.pop().foreign_keys:
                dependency = foreign_key.column.table
                if dependency not in tables:
                    tables.add(dependency)
                    pending.append(dependency)
        Base.metadata.create_all(engine, tables=list(tables))
        factory = create_session_factory(engine)
        now = datetime.now(timezone.utc)
        hasher = PasswordHasher()
        with factory.begin() as session:
            session.add(User(id='staff', username='staff', username_normalized='staff',
                email='staff@example.test', email_normalized='staff@example.test', email_verified_at=now,
                phone='+8613800000000', phone_normalized='+8613800000000', phone_verified_at=now,
                password_hash=hasher.hash('correct password 123'), status=AccountStatus.ACTIVE,
                created_at=now, updated_at=now))
            session.add(UserRole(id='staff-role', user_id='staff', role_code=RoleCode.SUPPORT_AGENT,
                assigned_by='admin', assigned_at=now))
        sender = RecordingSmsSender()
        activation = StaffActivationService(factory,
            phone_otp=PhoneOtpService(factory, sender=sender, secret='staff-password-race', now=lambda: now),
            email_code_deriver=lambda _: '123456', now=lambda: now)
        challenge = activation.request(username='staff', password='correct password 123')
        activation.confirm(activation_id=challenge['activation_id'], code=sender.messages[-1][1])
        tokens = TokenService(factory, jwt_secret='staff-password-race-secret-at-least-thirty-two-bytes',
            jwt_issuer='liuhetong', now_factory=lambda: now)
        mobile = tokens.issue_pair(user_id='staff', device_key='mobile', display_name='Mobile')
        admin = tokens.issue_admin_pair(user_id='staff', display_name='Staff browser', staff_only=True)
        recovery = PasswordRecoveryService(factory, password_hasher=hasher,
            token_codec=PasswordResetTokenCodec(b'staff-password-race-reset-secret'), now_factory=lambda: now)
        staff_password = StaffPasswordService(factory, tokens=tokens, recovery=recovery, now_factory=lambda: now)
        yield factory, tokens, mobile, admin, recovery, staff_password, now, activation, sender
    finally:
        engine.dispose()
        with admin_engine.begin() as connection:
            connection.execute(text(f'DROP SCHEMA "{schema}" CASCADE'))
        admin_engine.dispose()


def test_mail_reset_and_staff_change_have_one_winner_without_deadlock(components):
    factory, tokens, mobile, admin, recovery, staff_password, _, _, _ = components
    link = recovery.request('staff@example.test')
    barrier = Barrier(2)

    def mail_reset():
        barrier.wait(timeout=10)
        try:
            recovery.reset(link, 'mail reset password 456')
            return 'success'
        except AppError as error:
            return error.code

    def staff_change():
        barrier.wait(timeout=10)
        try:
            staff_password.change(access_token=admin.access_token, refresh_cookie=admin.refresh_token,
                current_password='correct password 123', new_password='staff changed password 456',
                trace_id='staff-race')
            return 'success'
        except AppError as error:
            return error.code

    with ThreadPoolExecutor(max_workers=2) as pool:
        outcomes = [pool.submit(mail_reset), pool.submit(staff_change)]
        results = [future.result(timeout=20) for future in outcomes]
    assert results.count('success') == 1, results
    with factory() as session:
        assert len(session.scalars(select(SecurityHold).where(SecurityHold.user_id == 'staff')).all()) == 1
        assert len(session.scalars(select(AuditEvent).where(AuditEvent.action == 'identity.password.reset')).all()) == 1
        assert len(session.scalars(select(OutboxEvent).where(
            OutboxEvent.event_type == 'identity.password.reset')).all()) == 1
    with pytest.raises(AppError):
        tokens.rotate(mobile.refresh_token)
    with pytest.raises(AppError):
        recovery.reset(link, 'stale link password 456')


def test_revoke_commits_before_staff_change_rejects_password_write(components):
    factory, _, _, admin, _, staff_password, now, _, _ = components
    control = AdminControlService(factory, now_factory=lambda: now)
    paused = Event()
    release = Event()
    started = Event()
    original_record = control._record
    original_decode = staff_password._tokens.decode_access_token

    def pause_before_commit(*args, **kwargs):
        paused.set()
        assert release.wait(timeout=10)
        return original_record(*args, **kwargs)

    def note_started(token):
        started.set()
        return original_decode(token)

    control._record = pause_before_commit
    staff_password._tokens.decode_access_token = note_started

    def revoke():
        return control.revoke_support_role(actor_id='admin', user_id='staff',
            role_code=RoleCode.SUPPORT_AGENT, idempotency_key='revoke-race', trace_id='revoke-race')

    def change():
        try:
            staff_password.change(access_token=admin.access_token, refresh_cookie=admin.refresh_token,
                current_password='correct password 123', new_password='staff changed password 456',
                trace_id='staff-race')
            return 'success'
        except AppError as error:
            return error.code

    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            revoke_future = pool.submit(revoke)
            assert paused.wait(timeout=10)
            change_future = pool.submit(change)
            assert started.wait(timeout=10)
            release.set()
            assert revoke_future.result(timeout=20)['status'] == 'REVOKED'
            assert change_future.result(timeout=20) != 'success'
    finally:
        release.set()
        control._record = original_record
        staff_password._tokens.decode_access_token = original_decode
    with factory() as session:
        assert PasswordHasher().verify(session.get(User, 'staff').password_hash, 'correct password 123')
        assert session.scalar(select(SecurityHold).where(SecurityHold.user_id == 'staff')) is None


def test_role_grant_commits_before_activation_cannot_use_old_identity_digest(components):
    factory, _, _, _, _, _, now, activation, sender = components
    with factory.begin() as session:
        session.delete(session.get(StaffActivation, 'staff'))
    challenge = activation.request(username='staff', password='correct password 123')
    code = sender.messages[-1][1]
    control = AdminControlService(factory, now_factory=lambda: now)
    paused, release, started = Event(), Event(), Event()
    original_record = control._record
    original_verify = activation.phone_otp.verify_code

    def pause_grant(*args, **kwargs):
        paused.set()
        assert release.wait(timeout=10)
        return original_record(*args, **kwargs)

    def note_confirm(*args, **kwargs):
        started.set()
        return original_verify(*args, **kwargs)

    control._record = pause_grant
    activation.phone_otp.verify_code = note_confirm

    def grant():
        return control.set_support_role(actor_id='admin', target='staff',
            role_code=RoleCode.FINANCE_SUPPORT, idempotency_key='grant-race',
            trace_id='grant-race')

    def confirm():
        try:
            activation.confirm(activation_id=challenge['activation_id'], code=code)
            return 'success'
        except AppError as error:
            return error.code

    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            grant_future = pool.submit(grant)
            assert paused.wait(timeout=10)
            confirm_future = pool.submit(confirm)
            assert started.wait(timeout=10)
            release.set()
            assert grant_future.result(timeout=20)['status'] == 'ASSIGNED'
            assert confirm_future.result(timeout=20) != 'success'
    finally:
        release.set()
        control._record = original_record
        activation.phone_otp.verify_code = original_verify
    with factory() as session:
        assert session.get(StaffActivation, 'staff') is None
        assert session.scalar(select(UserRole).where(UserRole.user_id == 'staff',
            UserRole.role_code == RoleCode.FINANCE_SUPPORT)) is not None


def test_staff_change_commits_before_otp_recovery_proof_is_rejected(components):
    factory, _, _, admin, recovery, staff_password, now, _, _ = components
    sender = RecordingSmsSender()
    otp = PhoneOtpService(factory, sender=sender, secret='staff-recovery-race', now=lambda: now)
    with factory() as session:
        snapshot = contact_snapshot(session.get(User, 'staff'), 'phone')
    otp.issue(purpose='password_reset_phone', phone='+8613800000000',
        user_id='staff', registration_session=snapshot)
    code = sender.messages[-1][1]
    credentials = AccountCredentialsService(factory, otp=otp, recovery=recovery,
        email_code_deriver=lambda _: '123456', now_factory=lambda: now)
    paused, release, started = Event(), Event(), Event()
    original_reset = recovery.reset_in_session
    original_verify = otp.verify_code

    def pause_password_change(*args, **kwargs):
        result = original_reset(*args, **kwargs)
        paused.set()
        assert release.wait(timeout=10)
        return result

    def note_verify(*args, **kwargs):
        started.set()
        return original_verify(*args, **kwargs)

    recovery.reset_in_session = pause_password_change
    otp.verify_code = note_verify

    def change():
        return staff_password.change(access_token=admin.access_token,
            refresh_cookie=admin.refresh_token, current_password='correct password 123',
            new_password='staff changed password 456', trace_id='staff-race')

    def verify():
        try:
            credentials.verify_password_code(channel='phone', target='+8613800000000',
                code=code, user_id='staff')
            return 'success'
        except AppError as error:
            return error.code

    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            change_future = pool.submit(change)
            assert paused.wait(timeout=10)
            verify_future = pool.submit(verify)
            assert started.wait(timeout=10)
            release.set()
            change_future.result(timeout=20)
            assert verify_future.result(timeout=20) == 'PASSWORD_RESET_INVALID'
    finally:
        release.set()
        recovery.reset_in_session = original_reset
        otp.verify_code = original_verify
    with factory() as session:
        assert PasswordHasher().verify(session.get(User, 'staff').password_hash,
            'staff changed password 456')
        assert session.scalar(select(OtpChallenge).where(OtpChallenge.user_id == 'staff',
            OtpChallenge.purpose == 'password_reset_grant',
            OtpChallenge.consumed_at.is_(None), OtpChallenge.invalidated_at.is_(None))) is None
