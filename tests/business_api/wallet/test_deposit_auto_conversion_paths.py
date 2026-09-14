from decimal import Decimal
from datetime import timedelta
from uuid import uuid4

import pytest

from app.modules.ledger.service import LedgerService
from app.modules.identity.enums import HoldType
from app.modules.identity.models import SecurityHold
from app.modules.wallet.models import WalletControl, WalletConversion, WalletLedgerTransaction, WalletSafetyState

import test_deposit_receipts as receipts
from test_admin_deposit_repairs import execute, preview, repair
from test_manual_deposit_cases import _service, manual_core  # noqa: F401


def _enable(core):
    core[0].deposit_auto_conversion_enabled = True
    core[0].reserve_policy = core[0].wallet_ledger.reserve_policy = 'manual_liquidity'
    with core[1].begin() as session:
        session.get(WalletControl, 'global').withdrawals_paused = False


@pytest.fixture
def auto_core():
    from app.modules.wallet import repair_models  # noqa: F401
    yield from receipts.core.__wrapped__()


@pytest.fixture
def repair_auto(auto_core):
    return repair.__wrapped__(auto_core)


def test_auto_ingest_converts_the_credited_receipt_once(auto_core):
    _enable(auto_core)
    receipts.intent(auto_core)
    first = receipts.ingest(auto_core)[0]
    assert first['status'] == 'CREDITED'
    assert auto_core[0].wallet_ledger.balance('alice') == Decimal('0')
    assert LedgerService(auto_core[1]).balance('alice') == Decimal('10')
    assert receipts.ingest(auto_core)[0]['id'] == first['id']
    with auto_core[1]() as session:
        assert session.query(WalletConversion).count() == 1


def test_normal_repair_converts_in_the_existing_credit_transaction(repair_auto):
    service, _, _ = repair_auto
    service.receipts.deposit_auto_conversion_enabled = True
    value = preview(repair_auto)
    result = execute(repair_auto, value, 'auto-repair', 'auto-repair-operation')
    assert result['conversion']['target_amount'] == '10.00'
    assert service.receipts.wallet_ledger.balance('alice') == Decimal('0')
    assert LedgerService(service.factory).balance('alice') == Decimal('10')


def test_manual_case_converts_in_the_existing_credit_transaction(manual_core):
    service, receipt = _service(manual_core)
    _enable(manual_core)
    service.receipts.deposit_auto_conversion_enabled = True
    case = service.create(actor_id='owner', receipt_id=receipt['id'], user_id='alice',
        reason_detail='自动兑换人工补录', ownership_attestation=True, idempotency_key='auto-case', authorize=lambda s: lambda: None)
    service.decide(actor_id='owner', case_id=case['case_id'], decision='APPROVED', reason_detail='批准',
        confirmed=True, idempotency_key='auto-decision', authorize=lambda s: lambda: None)
    value = service.preview(actor_id='owner', case_id=case['case_id'], authorize=lambda s: lambda: None)
    result = service.execute(actor_id='owner', case_id=case['case_id'], preview_id=value['preview_id'], digest=value['digest'],
        expected_version=1, operation_id='auto-manual-operation', idempotency_key='auto-manual-execute', authorize=lambda s: lambda: None)
    assert result['conversion']['target_amount'] == '10.00'
    assert service.receipts.wallet_ledger.balance('alice') == Decimal('0')
    assert LedgerService(service.factory).balance('alice') == Decimal('10')


def test_auto_second_leg_failure_keeps_review_and_can_retry(auto_core, monkeypatch):
    service, factory, _, _, Receipt, _ = auto_core
    _enable(auto_core)
    receipts.intent(auto_core)
    original_post = LedgerService.post

    def stale_second_leg(*args, **kwargs):
        raise ValueError('reserve evidence stale')

    monkeypatch.setattr(LedgerService, 'post', stale_second_leg)
    result = receipts.ingest(auto_core)[0]
    assert result['status'] == 'REVIEW'
    assert result['reason_code'] == 'AUTO_CONVERSION_RETRY_REQUIRED'
    with factory() as session:
        row = session.get(Receipt, result['id'])
        assert row.pending_obligation is True
        assert row.ledger_transaction_id is None
        assert session.query(WalletLedgerTransaction).count() == 0
        assert session.query(WalletConversion).count() == 0

    monkeypatch.setattr(LedgerService, 'post', original_post)
    retried = service.retry_credit(result['id'], actor_id='receipt-worker')
    assert retried['status'] == 'CREDITED'
    assert service.wallet_ledger.balance('alice') == Decimal('0')
    assert LedgerService(factory).balance('alice') == Decimal('10')


@pytest.mark.parametrize('restriction', ['global', 'recovery_hold'])
def test_auto_known_restrictions_keep_review_receipt(auto_core, restriction):
    service, factory, _, _, Receipt, now = auto_core
    _enable(auto_core)
    receipts.intent(auto_core)
    with factory.begin() as session:
        if restriction == 'global':
            session.add(WalletSafetyState(id='global', restricted=True, epoch=1, reason='fixture'))
        else:
            session.add(SecurityHold(id=str(uuid4()), user_id='alice', hold_type=HoldType.WITHDRAWAL,
                reason_code='fixture', starts_at=now-timedelta(seconds=1), ends_at=now+timedelta(minutes=5),
                created_at=now))
    result = receipts.ingest(auto_core)[0]
    assert result['status'] == 'REVIEW'
    assert result['reason_code'] == 'AUTO_CONVERSION_RETRY_REQUIRED'
    with factory() as session:
        row = session.get(Receipt, result['id'])
        assert row.pending_obligation is True
        assert row.ledger_transaction_id is None
        assert session.query(WalletConversion).count() == 0
