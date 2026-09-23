"""Concurrency probes against an explicitly isolated, fresh PostgreSQL schema."""
import os
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from uuid import uuid4

import pytest
from sqlalchemy import create_engine, select, text
from sqlalchemy.orm import sessionmaker

from app.core.database import Base
from app.core.errors import AppError
from app.core.outbox import OutboxEvent
from app.modules.identity.enums import AccountStatus
from app.modules.identity.invitations import InvitationService
from app.modules.identity.models import User, Invitation
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.phone import PhoneAuthService, PhoneOtpService, RecordingSmsSender
from app.modules.identity.registration import RegistrationService, VerificationTokenCodec
from app.modules.identity.tokens import TokenService
from test_phone_auth import Clock
import app.modules.audit.models  # noqa: F401


def test_parallel_verified_signup_and_ticket_exchange_each_have_one_winner():
    url = os.environ.get('PHONE_ONBOARDING_POSTGRES_URL')
    if not url:
        pytest.skip('isolated PostgreSQL URL not provided')
    schema = 'phone_onboarding_' + uuid4().hex
    engine = create_engine(url, connect_args={'options': '-csearch_path=' + schema}, pool_size=10)
    assert engine.dialect.name == 'postgresql'
    with engine.begin() as connection:
        connection.execute(text('CREATE SCHEMA ' + schema))
    Base.metadata.create_all(engine)
    factory = sessionmaker(engine, expire_on_commit=False)
    clock = Clock()
    invitation = InvitationService(factory, now_factory=clock)
    invitation.issue(code='concurrency-invite', max_uses=1,
        expires_at=clock()+timedelta(days=1), created_by='test')
    registration = RegistrationService(factory, invitation_service=invitation,
        password_hasher=PasswordHasher(), token_codec=VerificationTokenCodec(b'phone-onboarding-test-secret'), now_factory=clock)
    sender = RecordingSmsSender()
    otp = PhoneOtpService(factory, sender=sender, secret='isolated-otp-secret', now=clock)
    auth = PhoneAuthService(factory, otp=otp, now=clock, registration=registration)
    auth.request_login_otp(phone='13800000001')
    def signup(_):
        try:
            return auth.login(phone='13800000001', code=sender.messages[-1][1], tokens=None,
                device_key='parallel-device', device_name='test',
                invitation_code='concurrency-invite', terms_accepted=True)
        except AppError as error:
            return error.code
    try:
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(signup, range(8)))
        winners = [result for result in results if isinstance(result, dict)]
        assert len(winners) == 1
        assert results.count('OTP_INVALID') == 7
        with factory.begin() as session:
            users = session.scalars(select(User)).all()
            assert len(users) == 1
            assert session.scalar(select(Invitation)).use_count == 1
            assert len(session.scalars(select(OutboxEvent)).all()) == 1
            users[0].status = AccountStatus.ACTIVE
            users[0].matrix_user_id = '@opaque:test'
        tokens = TokenService(factory, jwt_secret='isolated-test-jwt-secret-at-least-32', jwt_issuer='test', now_factory=clock)
        def exchange(_):
            try:
                return auth.complete_login(login_ticket=winners[0]['login_ticket'],
                    device_key='parallel-device', device_name='test', tokens=tokens)
            except AppError as error:
                return error.code
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(exchange, range(8)))
        assert sum(hasattr(result, 'access_token') for result in results) == 1
        assert results.count('LOGIN_TICKET_INVALID') == 7
    finally:
        # Only this test's freshly generated, fixed-prefix schema is removed.
        with engine.begin() as connection:
            connection.execute(text('DROP SCHEMA ' + schema + ' CASCADE'))
        engine.dispose()
