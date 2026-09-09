from datetime import timedelta
from decimal import Decimal

import pytest
from sqlalchemy import select, func

from test_deposit_receipts import core as receipt_core, intent
from test_manual_payouts import core as payout_core, claim, evidence
from app.modules.wallet.models import WalletLedgerTransaction


def test_receipt_lock_wait_cannot_credit_expired_evidence(receipt_core, monkeypatch):
    from app.modules.wallet import receipts
    from app.integrations.tron.finality import TronEvidenceUnavailable
    c = receipt_core
    intent(c)
    clock = [c[5]+timedelta(seconds=3)]
    c[0].clock = lambda:clock[0]
    original = receipts.lock_budget
    def delayed(session):
        result = original(session)
        clock[0] += timedelta(seconds=121)
        return result
    monkeypatch.setattr(receipts, 'lock_budget', delayed)
    with pytest.raises(TronEvidenceUnavailable):
        c[0].ingest(c[2].value.txid, actor_id='test')
    with c[1]() as session:
        assert session.scalar(select(func.count()).select_from(WalletLedgerTransaction)) == 0


def test_payout_lock_wait_keeps_hold_when_evidence_expires(payout_core, monkeypatch):
    c = payout_core
    order = claim(c)
    c[6].evidence = evidence(c)
    from app.integrations.tron.finality import transaction_evidence_fresh
    assert transaction_evidence_fresh(c[6].evidence, c[2][0])
    c[0].submit_txid(admin_id='owner', order_id=order['id'], txid=c[6].evidence.txid, idempotency_key='txid')
    original = c[0]._order_lock
    def delayed(session, order_id):
        result = original(session, order_id)
        c[2][0] += timedelta(seconds=121)
        return result
    monkeypatch.setattr(c[0], '_order_lock', delayed)
    result = c[0].reconcile(order_id=order['id'])
    assert result['status'] == 'UNKNOWN'
    assert c[5].balance('HOLD:alice') == Decimal('10')


def test_receipt_binding_lock_wait_rechecks_before_credit(receipt_core, monkeypatch):
    from app.integrations.tron.finality import TronEvidenceUnavailable, transaction_evidence_fresh
    c = receipt_core
    intent(c)
    clock = [c[5]+timedelta(seconds=3)]
    assert transaction_evidence_fresh(c[2].value, clock[0])
    c[0].clock = lambda:clock[0]
    original = c[0]._match
    def delayed(*args, **kwargs):
        result = original(*args, **kwargs)
        clock[0] += timedelta(seconds=121)
        return result
    monkeypatch.setattr(c[0], '_match', delayed)
    with pytest.raises(TronEvidenceUnavailable):
        c[0].ingest(c[2].value.txid, actor_id='test')
    with c[1]() as session:
        assert session.scalar(select(func.count()).select_from(WalletLedgerTransaction)) == 0
