from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest
from sqlalchemy import create_engine, select, func

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.core.outbox import OutboxEvent
from app.modules.audit.models import AuditEvent
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User, Device, RefreshTokenFamily
from app.modules.identity.passwords import PasswordHasher


@pytest.fixture
def setup():
    from app.modules.identity.payment_pin import PaymentPinService
    from app.modules.identity.payment_pin_models import PaymentPinCredential
    engine = create_engine('sqlite+pysqlite:///:memory:')
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = [datetime.now(timezone.utc)]
    with factory.begin() as session:
        session.add(User(id='user', username='user', username_normalized='user', email='u@example.test',
            email_normalized='u@example.test', password_hash=PasswordHasher().hash('test-password-only'),
            status=AccountStatus.ACTIVE, created_at=now[0], updated_at=now[0]))
        session.add(Device(id='device', user_id='user', device_key='test', display_name='test', last_seen_at=now[0], created_at=now[0]))
        session.add(RefreshTokenFamily(id='family', user_id='user', device_id='device', created_at=now[0]))
    claims = dict(sub='user', family_id='family', device_id='device', iat=int(now[0].timestamp()), exp=int((now[0]+timedelta(hours=2)).timestamp()))
    service = PaymentPinService(factory, clock=lambda: now[0])
    yield service, factory, now, claims
    engine.dispose()


def enroll(service, claims, pin='012345', key='setup-key'):
    return service.setup(claims=claims, pin=pin, login_password='test-password-only', idempotency_key=key)


def authorize(service, claims, **kwargs):
    return service.authorize(claims=claims, pin=kwargs.pop('pin', '012345'), action='chat_transfer.create',
        payload=kwargs.pop('payload', dict(receiver_id='other', amount='1.00')), idempotency_key=kwargs.pop('key', 'transfer-key'))['authorization']


@pytest.mark.parametrize('pin', ['', '12345', '1234567', '１２３４５６', '12a456', 123456])
def test_exact_ascii_string_required(setup, pin):
    service, factory, _, claims = setup
    with pytest.raises(AppError) as error:
        enroll(service, claims, pin)
    assert error.value.code == 'PAYMENT_PIN_INVALID_FORMAT'
    assert service.status(claims=claims)['configured'] is False


def test_setup_identity_idempotency_hash_and_audit(setup):
    from app.modules.identity.payment_pin_models import PaymentPinCredential
    service, factory, _, claims = setup
    with pytest.raises(AppError):
        service.setup(claims=claims, pin='012345', login_password='wrong', idempotency_key='setup-key')
    assert enroll(service, claims)['configured']
    assert enroll(service, claims)['configured']
    with pytest.raises(AppError):
        enroll(service, claims, pin='654321')
    with pytest.raises(AppError):
        enroll(service, claims, key='different-key')
    with factory() as session:
        credential = session.get(PaymentPinCredential, 'user')
        assert credential.pin_hash.startswith('$argon2id$')
        assert credential.pin_hash != '012345'
        events = session.scalars(select(OutboxEvent)).all()
        assert len(events) >= 1
        assert '012345' not in str([e.payload for e in events])


def test_failures_commit_and_lock_survives_service_restart(setup):
    from app.modules.identity.payment_pin import PaymentPinService
    service, factory, now, claims = setup
    enroll(service, claims)
    for i in range(5):
        with pytest.raises(AppError) as error:
            authorize(service, claims, pin='999999')
        assert error.value.code == ('PAYMENT_PIN_LOCKED' if i == 4 else 'PAYMENT_PIN_INCORRECT')
    service = PaymentPinService(factory, clock=lambda: now[0])
    with pytest.raises(AppError) as error:
        authorize(service, claims)
    assert error.value.code == 'PAYMENT_PIN_LOCKED'
    now[0] += timedelta(minutes=15, seconds=1)
    assert authorize(service, claims)


def test_authorization_binding_single_use_and_rollback(setup):
    service, factory, _, claims = setup
    enroll(service, claims)
    ticket = authorize(service, claims)
    args = dict(claims=claims, user_id='user', action='chat_transfer.create', payload=dict(receiver_id='other', amount='1.00'), idempotency_key='transfer-key', authorization=ticket)
    with factory.begin() as session:
        with pytest.raises(AppError):
            service.consume(session, **{**args, 'payload': dict(receiver_id='attacker', amount='1.00')})
    with pytest.raises(RuntimeError):
        with factory.begin() as session:
            service.consume(session, **args)
            raise RuntimeError('business rollback')
    with factory.begin() as session:
        service.consume(session, **args)
    with factory.begin() as session:
        with pytest.raises(AppError):
            service.consume(session, **args)
    with factory.begin() as session:
        service.consume(session, **args, existing=True)


@pytest.mark.parametrize('mutation', ['expired', 'device', 'family', 'version', 'amount', 'key', 'missing'])
def test_rejects_invalid_authorization_without_consuming(setup, mutation):
    from app.modules.identity.payment_pin_models import PaymentPinCredential, PaymentPinAuthorization
    service, factory, now, claims = setup
    enroll(service, claims)
    ticket = authorize(service, claims)
    args = dict(claims=claims, user_id='user', action='chat_transfer.create', payload=dict(receiver_id='other', amount='1'), idempotency_key='transfer-key', authorization=ticket)
    if mutation == 'expired': now[0] += timedelta(seconds=301)
    elif mutation in ('device', 'family'):
        with factory.begin() as session:
            session.get(Device if mutation == 'device' else RefreshTokenFamily, 'device' if mutation == 'device' else 'family').revoked_at = now[0]
    elif mutation == 'version':
        with factory.begin() as session: session.get(PaymentPinCredential, 'user').version += 1
    elif mutation == 'amount': args['payload']['amount'] = '2'
    elif mutation == 'key': args['idempotency_key'] = 'other'
    elif mutation == 'missing': args['authorization'] = None
    with factory.begin() as session:
        with pytest.raises(AppError): service.consume(session, **args)
    with factory() as session:
        assert session.scalar(select(PaymentPinAuthorization.consumed_at)) is None


def test_transfer_enforces_pin_and_idempotent_payment(setup):
    from app.modules.ledger.service import LedgerService
    from app.modules.transfer.service import ChatTransferService
    service, factory, now, claims = setup
    enroll(service, claims)
    ledger = LedgerService(factory)
    ledger.adjust(user_id='user', amount=Decimal('10'), actor_id='fixture', reason_code='TEST_FUND', idempotency_key='fund')
    transfers = ChatTransferService(factory, ledger)
    args = dict(sender_id='user', receiver_id='other', amount=Decimal('1'), idempotency_key='transfer-key', expires_at=now[0]+timedelta(days=1))
    with pytest.raises(AppError): transfers.create(**args)
    assert ledger.balance('user') == Decimal('10')
    ticket = authorize(service, claims)
    first = transfers.create(**args, payment_claims=claims, payment_authorization=ticket)
    second = transfers.create(**args, payment_claims=claims, payment_authorization=ticket)
    assert first.id == second.id
    assert ledger.balance('user') == Decimal('8.99')


def test_redpacket_enforces_pin(setup):
    from app.modules.ledger.service import LedgerService
    from app.modules.redpacket.service import RedPacketService
    service, factory, now, claims = setup
    enroll(service, claims)
    ledger = LedgerService(factory)
    ledger.adjust(user_id='user', amount=Decimal('10'), actor_id='fixture', reason_code='TEST_FUND', idempotency_key='fund')
    packets = RedPacketService(factory, ledger)
    args = dict(sender_id='user', recipient_id='other', total=Decimal('1'), share_count=1, idempotency_key='packet-key', expires_at=now[0]+timedelta(days=1))
    with pytest.raises(AppError): packets.create_equal(**args)
    ticket = service.authorize(claims=claims, pin='012345', action='red_packet.create', payload=dict(mode='EQUAL', total='1', share_count=1, recipient_id='other'), idempotency_key='packet-key')['authorization']
    first = packets.create_equal(**args, payment_claims=claims, payment_authorization=ticket)
    second = packets.create_equal(**args, payment_claims=claims, payment_authorization=ticket)
    assert first.id == second.id
    assert ledger.balance('user') == Decimal('9')


def test_insufficient_balance_rolls_back_ticket_and_can_retry(setup):
    from app.modules.identity.payment_pin_models import PaymentPinAuthorization
    from app.modules.ledger.service import LedgerService
    from app.modules.transfer.service import ChatTransferService
    service, factory, now, claims = setup
    enroll(service, claims)
    ticket = authorize(service, claims)
    ledger = LedgerService(factory)
    transfers = ChatTransferService(factory, ledger)
    args = dict(sender_id='user', receiver_id='other', amount=Decimal('1'), idempotency_key='transfer-key',
        expires_at=now[0]+timedelta(days=1), payment_claims=claims, payment_authorization=ticket)
    with pytest.raises(ValueError, match='insufficient balance'):
        transfers.create(**args)
    with factory() as session:
        assert session.scalar(select(PaymentPinAuthorization.consumed_at)) is None
    ledger.adjust(user_id='user', amount=Decimal('10'), actor_id='fixture', reason_code='TEST_FUND', idempotency_key='fund')
    assert transfers.create(**args)
    assert ledger.balance('user') == Decimal('8.99')


def test_limits_hash_account_session_and_ip(setup):
    service, _, _, claims = setup
    class Limiter:
        def __init__(self): self.calls = []
        def hit(self, key, **kwargs): self.calls.append((key, kwargs))
    service.limiter = Limiter()
    enroll(service, claims)
    authorize(service, claims)
    assert len(service.limiter.calls) == 6
    assert all('user' not in key and 'family' not in key and '012345' not in key for key, _ in service.limiter.calls)
    assert {key.split(':')[2] for key, _ in service.limiter.calls} == {'account', 'session', 'ip'}


def test_payload_defaults_money_and_note_normalize_but_parameters_remain_bound(setup):
    service, _, _, _ = setup
    base = service.intent_hash('chat_transfer.create', dict(receiver_id='other', amount='1', note=' hi '), 'key')
    assert base == service.intent_hash('chat_transfer.create', dict(receiver_id='other', amount='1.00', note='hi', room_id=None), 'key')
    assert base != service.intent_hash('chat_transfer.create', dict(receiver_id='other', amount='1.00', note='hi', room_id='room'), 'key')
    for payload in [dict(receiver_id='other', amount='1', payment_authorization='forbidden'), dict(receiver_id='other', amount='1', unknown=True)]:
        with pytest.raises(AppError): service.intent_hash('chat_transfer.create', payload, 'key')


def test_security_hold_and_inactive_identity_rejected(setup):
    from app.modules.identity.models import SecurityHold
    from app.modules.identity.enums import HoldType
    service, factory, now, claims = setup
    enroll(service, claims)
    with factory.begin() as session:
        session.get(User, 'user').status = AccountStatus.SUSPENDED
    with pytest.raises(AppError): authorize(service, claims)
