from decimal import Decimal

import pytest
from sqlalchemy import select, func

from app.core.errors import AppError
from app.core.outbox import OutboxEvent
from app.modules.audit.models import AuditEvent
from app.modules.wallet.models import WalletLedgerTransaction
from app.modules.wallet.safety import usdt_liability
from tests.business_api.wallet.test_deposit_receipts import core, intent, ingest


def cancel(core, intent_id, key='cancel-one', user='alice'):
    return core[3].cancel(user_id=user, intent_id=intent_id, idempotency_key=key)


def test_cancel_replay_ownership_and_no_money_write(core):
    original = intent(core)
    with pytest.raises(AppError, match='WALLET_DEPOSIT_INTENT_NOT_FOUND'):
        cancel(core, original['id'], user='bob')
    result = cancel(core, original['id'])
    assert result['status'] == 'CANCELLED'
    assert result['closed_at'] is not None
    assert cancel(core, original['id']) == result
    assert core[3].current(user_id='alice') is None
    with pytest.raises(AppError, match='WALLET_DEPOSIT_INTENT_CANNOT_CANCEL'):
        cancel(core, original['id'], key='different')
    with core[1]() as session:
        assert session.scalar(select(func.count()).select_from(WalletLedgerTransaction)) == 0
        assert session.scalar(select(func.count()).select_from(AuditEvent).where(
            AuditEvent.reason_code == 'WALLET_DEPOSIT_INTENT_CANCELLED')) == 1
        assert session.scalar(select(func.count()).select_from(OutboxEvent).where(
            OutboxEvent.event_type == 'wallet.deposit_intent_closed',
            OutboxEvent.aggregate_id == original['id'])) == 1


def test_cancel_key_cannot_target_another_intent(core):
    first = intent(core)
    cancel(core, first['id'])
    second = core[3].create(user_id='alice', expected_amount='11.000000', expected_binding_version=1, idempotency_key='second')
    with pytest.raises(AppError, match='WALLET_IDEMPOTENCY_CONFLICT'):
        cancel(core, second['id'])


def test_cancel_preserves_later_receipt_for_review_and_obligation(core):
    first = intent(core)
    cancel(core, first['id'])
    receipt = ingest(core)[0]
    assert receipt['status'] == 'REVIEW'
    assert receipt['reason_code'] == 'INTENT_CANCELLED'
    assert core[0].wallet_ledger.balance('alice') == Decimal('0')
    with core[1]() as session:
        assert usdt_liability(session) == Decimal('10')
    assert ingest(core)[0]['id'] == receipt['id']


def test_fulfilled_receipt_wins_and_cannot_be_cancelled(core):
    first = intent(core)
    assert ingest(core)[0]['status'] == 'CREDITED'
    with pytest.raises(AppError, match='WALLET_DEPOSIT_INTENT_CANNOT_CANCEL'):
        cancel(core, first['id'])


def test_cancel_audit_failure_rolls_back_intent_and_command(core, monkeypatch):
    from app.modules.wallet import funding
    from app.modules.wallet.funding_models import DepositIntentCancellation
    first = intent(core)
    def fail(*args):
        raise RuntimeError('audit unavailable')
    monkeypatch.setattr(funding, 'audit_write', fail)
    with pytest.raises(RuntimeError, match='audit unavailable'):
        cancel(core, first['id'])
    assert core[3].status(user_id='alice', intent_id=first['id'])['status'] == 'OPEN'
    with core[1]() as session:
        assert session.scalar(select(DepositIntentCancellation)) is None


def test_expired_intent_cannot_cancel(core):
    from datetime import timedelta
    first = intent(core)
    core[3].clock = lambda: core[5] + timedelta(minutes=20)
    with pytest.raises(AppError, match='WALLET_DEPOSIT_INTENT_CANNOT_CANCEL'):
        cancel(core, first['id'])
