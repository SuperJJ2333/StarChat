"""Run against an explicitly supplied isolated PostgreSQL service, never live data.

Each test owns a new randomly named schema and drops only that schema afterward.
Set PAYMENT_PIN_TEST_DATABASE_URL to the rehearsal database, not production.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from decimal import Decimal
import os
from uuid import uuid4

import pytest
from sqlalchemy import create_engine, event, select, text, func

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User, Device, RefreshTokenFamily
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.payment_pin import PaymentPinService
from app.modules.identity.payment_pin_models import PaymentPinCredential
from app.modules.ledger.models import LedgerEntry
from app.modules.ledger.service import LedgerService
from app.modules.transfer.service import ChatTransferService


@pytest.fixture
def pg():
    url = os.environ.get('PAYMENT_PIN_TEST_DATABASE_URL')
    if not url:
        pytest.skip('isolated PostgreSQL URL not configured')
    if not url.startswith('postgresql'):
        pytest.fail('payment concurrency tests require PostgreSQL')
    schema = 'payment_pin_test_' + uuid4().hex
    bootstrap = create_engine(url)
    with bootstrap.begin() as conn:
        conn.execute(text(f'CREATE SCHEMA "{schema}"'))
    engine = create_engine(url, connect_args={'options': f'-csearch_path={schema}'})
    try:
        Base.metadata.create_all(engine)
        factory = create_session_factory(engine)
        now = datetime.now(timezone.utc)
        with factory.begin() as session:
            session.add(User(id='user', username='user', username_normalized='user', email='u@example.test',
                email_normalized='u@example.test', password_hash=PasswordHasher().hash('test-password-only'),
                status=AccountStatus.ACTIVE, created_at=now, updated_at=now))
            session.flush()
            session.add(Device(id='device', user_id='user', device_key='test', display_name='test', last_seen_at=now, created_at=now))
            session.flush()
            session.add(RefreshTokenFamily(id='family', user_id='user', device_id='device', created_at=now))
        claims = dict(sub='user', family_id='family', device_id='device', iat=int(now.timestamp()), exp=int((now+timedelta(hours=2)).timestamp()))
        yield PaymentPinService(factory), factory, claims, now
    finally:
        engine.dispose()
        with bootstrap.begin() as conn:
            conn.execute(text(f'DROP SCHEMA "{schema}" CASCADE'))
        bootstrap.dispose()


def test_concurrent_setup_cannot_overwrite(pg):
    service, factory, claims, _ = pg
    def setup(index):
        try:
            service.setup(claims=claims, pin='012345' if index == 0 else '654321', login_password='test-password-only', idempotency_key=str(index))
            return 'ok'
        except AppError as error:
            return error.code
    with ThreadPoolExecutor(max_workers=2) as executor:
        result = list(executor.map(setup, range(2)))
    assert sorted(result) == ['PAYMENT_PIN_ALREADY_CONFIGURED', 'ok']
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(PaymentPinCredential)) == 1


def test_concurrent_wrong_pin_attempts_cannot_lose_lockout(pg):
    service, factory, claims, _ = pg
    service.setup(claims=claims, pin='012345', login_password='test-password-only', idempotency_key='setup')
    def wrong(index):
        try:
            service.authorize(claims=claims, pin='000000', action='chat_transfer.create', payload=dict(receiver_id='other', amount='1'), idempotency_key=str(index))
        except AppError as error:
            return error.code
    with ThreadPoolExecutor(max_workers=5) as executor:
        results = list(executor.map(wrong, range(5)))
    assert results.count('PAYMENT_PIN_INCORRECT') == 4
    assert results.count('PAYMENT_PIN_LOCKED') == 1
    with factory() as session:
        assert session.get(PaymentPinCredential, 'user').failed_attempts == 5


def test_concurrent_create_same_ticket_debits_once(pg):
    service, factory, claims, now = pg
    service.setup(claims=claims, pin='012345', login_password='test-password-only', idempotency_key='setup')
    ledger = LedgerService(factory)
    ledger.adjust(user_id='user', amount=Decimal('10'), actor_id='fixture', reason_code='TEST_FUND', idempotency_key='fund')
    ticket = service.authorize(claims=claims, pin='012345', action='chat_transfer.create', payload=dict(receiver_id='other', amount='1'), idempotency_key='key')['authorization']
    def create(_):
        return ChatTransferService(factory, ledger).create(sender_id='user', receiver_id='other', amount=Decimal('1'),
            idempotency_key='key', expires_at=now+timedelta(days=1), payment_claims=claims, payment_authorization=ticket).id
    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(create, range(2)))
    assert results[0] == results[1]
    assert ledger.balance('user') == Decimal('8.99')
    with factory() as session:
        assert session.scalar(select(func.sum(LedgerEntry.amount))) == Decimal('0')
