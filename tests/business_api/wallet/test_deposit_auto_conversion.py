from datetime import datetime, timezone
from decimal import Decimal

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.pool import StaticPool

from app.core.database import Base, create_session_factory
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User
from app.modules.ledger.reserve import RedeemabilityReserve
from app.modules.ledger.service import LedgerService
from app.modules.wallet.receipt_models import DepositReceipt
from app.modules.wallet.models import WalletControl
from app.modules.wallet.service import WalletLedger


@pytest.fixture
def core():
    from app.modules.wallet import repair_models  # noqa: F401
    engine = create_engine('sqlite+pysqlite:///:memory:', poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(User(id='alice', username='alice', username_normalized='alice',
            email='alice@example.test', email_normalized='alice@example.test', password_hash='fixture',
            status=AccountStatus.ACTIVE, created_at=now, updated_at=now))
        session.add(WalletControl(id='global', withdrawals_paused=False, pause_reason=None))
        session.add(RedeemabilityReserve(id='global', eligible_usdt=Decimal('100'),
            usdt_liability=Decimal('10.123456'), version=0, pending_payouts=0,
            outgoing_restricted=False, observed_at=now))
        tx = WalletLedger(factory).post(entries={'alice': Decimal('10.123456'),
            'PLATFORM_CUSTODY': Decimal('-10.123456')}, actor_id='worker',
            reason_code='TRON_DEPOSIT_CREDIT', idempotency_key='receipt:r1',
            scope='wallet.deposit.receipt', session=session)
        session.add(DepositReceipt(id='r1', network='TRC20', contract='contract',
            txid='a' * 64, log_index=0, source_address='Tsource',
            official_address='Tofficial', official_config_version='v1',
            amount_units='10123456', amount=Decimal('10.123456'), block_number=1,
            block_id='b', block_time=now, evidence_policy='policy',
            evidence_source='source', observed_at=now, facts_digest='digest',
            status='CREDITED', reason_code='TRON_DEPOSIT_CREDIT',
            pending_obligation=False, intent_id='intent', user_id='alice',
            ledger_transaction_id=tx.id))
    yield factory
    engine.dispose()


def test_credited_receipt_auto_conversion_is_exact_replayable_and_attributes_actor(core):
    from app.modules.wallet.deposit_conversion import convert_credited_receipt
    with core.begin() as session:
        result = convert_credited_receipt(session, core, receipt_id='r1', actor_id='worker',
            enabled=True, reserve_policy='manual_liquidity')
        assert result['source_amount'] == '10.120000'
        assert result['target_amount'] == '10.12'
        assert result['remainder'] == '0.003456'
        assert result['receipt_id'] == 'r1'
        again = convert_credited_receipt(session, core, receipt_id='r1', actor_id='worker',
            enabled=True, reserve_policy='manual_liquidity')
        assert again == result
    assert WalletLedger(core).balance('alice') == Decimal('0.003456')
    assert LedgerService(core).balance('alice') == Decimal('10.12')


def test_credited_receipt_requires_original_exact_usdt_credit(core):
    from app.modules.wallet.deposit_conversion import convert_credited_receipt
    with core() as session:
        session.execute(DepositReceipt.__table__.update().where(DepositReceipt.id == 'r1').values(ledger_transaction_id='missing'))
        with pytest.raises(ValueError, match='receipt ledger evidence'):
            convert_credited_receipt(session, core, receipt_id='r1', actor_id='worker',
                enabled=True, reserve_policy='manual_liquidity')
    assert WalletLedger(core).balance('alice') == Decimal('10.123456')


def test_public_conversion_rejects_reserved_receipt_key(core):
    from app.modules.wallet.safety import WalletSafetyMixin
    from app.modules.wallet.service import WalletService
    assert WalletSafetyMixin._reserved_conversion_key('deposit-receipt:r1')
    assert not WalletSafetyMixin._reserved_conversion_key('client-key')
    service = WalletService(core, None, conversions_enabled=True,
        manual_runtime=type('Runtime', (), {'receipts': type('Receipts', (), {'reserve_policy': 'manual_liquidity'})()})())
    with pytest.raises(ValueError, match='invalid conversion intent'):
        service.convert('alice', 'USDT_TO_CAIBI', '1', 'deposit-receipt:r1')


def test_receipt_conversion_evidence_is_emitted_once(core):
    from app.core.outbox import OutboxEvent
    from app.modules.audit.models import AuditEvent
    from app.modules.wallet.deposit_conversion import convert_credited_receipt
    with core.begin() as session:
        convert_credited_receipt(session, core, receipt_id='r1', actor_id='worker', enabled=True,
            reserve_policy='manual_liquidity')
        convert_credited_receipt(session, core, receipt_id='r1', actor_id='other-worker', enabled=True,
            reserve_policy='manual_liquidity')
    with core() as session:
        audits = list(session.scalars(select(AuditEvent).where(AuditEvent.action == 'wallet.deposit_auto_converted')))
        outbox = list(session.scalars(select(OutboxEvent).where(OutboxEvent.event_type == 'wallet.deposit_auto_converted')))
        assert len(audits) == len(outbox) == 1
        assert audits[0].actor_id == 'worker'
        assert outbox[0].payload['receipt_id'] == 'r1'


def test_auto_conversion_defaults_off_and_requires_conversion_gate():
    from app.core.config import Settings
    from pydantic import ValidationError
    assert Settings().wallet_deposit_auto_conversion_enabled is False
    with pytest.raises(ValidationError, match='requires conversions enabled'):
        Settings(wallet_deposit_auto_conversion_enabled=True)
