from dataclasses import replace
from datetime import timedelta
from decimal import Decimal

import pytest
from sqlalchemy import select, func

from app.modules.ledger.reserve import RedeemabilityReserve
from app.modules.wallet.funding_models import DepositIntent
from app.modules.wallet.models import WalletLedgerTransaction
from app.modules.wallet.receipt_models import DepositReceiptAnomaly
from app.modules.wallet.safety import usdt_liability
from test_deposit_receipts import core, intent, ingest  # noqa: F401


def deferred(c):
    return c[0].ingest(c[2].value.txid,actor_id='receipt-worker',defer_credit=True)[0]


def retry(c,receipt_id):
    return c[0].retry_credit(receipt_id,actor_id='receipt-worker')


def test_deferred_without_reserve_keeps_obligation_without_ledger(core):
    first=intent(core)
    with core[1].begin() as s: s.delete(s.get(RedeemabilityReserve,'global'))
    row=deferred(core)
    assert row['reason_code']=='DEFERRED_RESERVE_CHECK' and row['status']=='REVIEW'
    with core[1]() as s:
        assert s.scalar(select(WalletLedgerTransaction)) is None
        assert usdt_liability(s)==Decimal('10')
        assert s.get(DepositIntent,first['id']).status=='OPEN'


@pytest.mark.parametrize('initial',['defer','reserve_failure'])
def test_restored_reserve_credits_open_intent_once(core,initial):
    first=intent(core)
    with core[1].begin() as s: s.get(RedeemabilityReserve,'global').observed_at=core[5]-timedelta(minutes=5)
    row=deferred(core) if initial=='defer' else ingest(core)[0]
    with core[1].begin() as s:
        reserve=s.get(RedeemabilityReserve,'global')
        reserve.observed_at=core[5]
        reserve.usdt_liability=10
    assert retry(core,row['id'])['status']=='CREDITED'
    assert retry(core,row['id'])['status']=='CREDITED'
    with core[1]() as s:
        assert s.scalar(select(func.count()).select_from(WalletLedgerTransaction))==1
        assert s.get(DepositIntent,first['id']).status=='FULFILLED'
        assert usdt_liability(s)==10
        assert not s.get(core[4],row['id']).pending_obligation


@pytest.mark.parametrize('change',['amount','missing'])
def test_retry_revalidates_complete_evidence(core,change):
    intent(core); row=deferred(core)
    evidence=core[2].value
    core[2].value=replace(evidence,transfers=() if change=='missing' else (replace(evidence.transfers[0],amount_units=11_000_000),))
    assert retry(core,row['id'])['status']=='QUARANTINED'
    with core[1]() as s:
        assert s.scalar(select(WalletLedgerTransaction)) is None
        assert s.scalar(select(DepositReceiptAnomaly)) is not None


@pytest.mark.parametrize('closed',['rebind','EXPIRED'])
def test_retry_cannot_reopen_closed_intent(core,closed):
    first=intent(core); row=deferred(core)
    with core[1].begin() as s:
        if closed=='rebind': core[3].close_by_rebind(s,user_id='alice',binding_id='binding',binding_version=1,actor_id='alice')
        else:
            value=s.get(DepositIntent,first['id']); value.status='EXPIRED'; value.closed_at=core[5]
    assert retry(core,row['id'])['status']=='REVIEW'
    with core[1]() as s: assert s.scalar(select(WalletLedgerTransaction)) is None


def test_multiple_matching_logs_cannot_be_retried_separately(core):
    intent(core)
    evidence=core[2].value
    core[2].value=replace(evidence,transfers=evidence.transfers+(replace(evidence.transfers[0],log_index=1),))
    rows=core[0].ingest(evidence.txid,actor_id='receipt-worker',defer_credit=True)
    assert all(row['reason_code']=='MULTIPLE_MATCHING_LOGS' for row in rows)
    for row in rows: assert retry(core,row['id'])['status']=='REVIEW'
    with core[1]() as s: assert s.scalar(select(WalletLedgerTransaction)) is None


@pytest.mark.parametrize('operation',['retry','ingest'])
def test_later_matching_log_counts_existing_deferred_receipt(core,operation):
    intent(core); row=deferred(core)
    evidence=core[2].value
    core[2].value=replace(evidence,transfers=evidence.transfers+(replace(evidence.transfers[0],log_index=1),))
    if operation=='retry': retry(core,row['id'])
    else: ingest(core)
    with core[1]() as s: assert s.scalar(select(WalletLedgerTransaction)) is None


def test_stale_reserve_remains_retryable_review(core):
    intent(core); row=deferred(core)
    with core[1].begin() as s: s.get(RedeemabilityReserve,'global').observed_at=core[5]-timedelta(minutes=5)
    result=retry(core,row['id'])
    assert result['status']=='REVIEW' and result['reason_code']=='RESERVE_UNAVAILABLE'


def test_retry_transaction_failure_rolls_back_all_effects(core,monkeypatch):
    from app.modules.wallet import receipts
    first=intent(core); row=deferred(core)
    def failure(*args): raise RuntimeError('audit-unavailable')
    monkeypatch.setattr(receipts,'audit_write',failure)
    with pytest.raises(RuntimeError): retry(core,row['id'])
    with core[1]() as s:
        assert s.scalar(select(WalletLedgerTransaction)) is None
        assert s.get(core[4],row['id']).pending_obligation
        assert s.get(DepositIntent,first['id']).status=='OPEN'
        assert usdt_liability(s)==10


def test_unknown_or_nonretryable_receipt_not_forced(core):
    with pytest.raises(ValueError): retry(core,'missing')
    row=ingest(core)[0]
    assert row['reason_code']=='NO_UNIQUE_INTENT'
    intent(core)
    assert retry(core,row['id'])['reason_code']=='NO_UNIQUE_INTENT'


def test_retry_provider_failure_preserves_pending(core):
    intent(core); row=deferred(core)
    def unavailable(txid): raise ValueError('provider unavailable')
    core[2].transaction_evidence=unavailable
    with pytest.raises(ValueError): retry(core,row['id'])
    with core[1]() as s:
        assert s.get(core[4],row['id']).reason_code=='DEFERRED_RESERVE_CHECK'
        assert s.scalar(select(WalletLedgerTransaction)) is None


def test_retry_rejects_changed_solidification_proof(core):
    intent(core); row=deferred(core)
    evidence=core[2].value
    core[2].value=replace(evidence,solid_head=replace(evidence.solid_head,height=1))
    with pytest.raises(ValueError): retry(core,row['id'])
    with core[1]() as s: assert s.scalar(select(WalletLedgerTransaction)) is None


def test_competing_retry_between_fetch_and_lock_is_idempotent(core):
    intent(core); row=deferred(core)
    original=core[2].transaction_evidence
    entered=[False]
    def evidence(txid):
        result=original(txid)
        if not entered[0]:
            entered[0]=True
            assert retry(core,row['id'])['status']=='CREDITED'
        return result
    core[2].transaction_evidence=evidence
    assert retry(core,row['id'])['status']=='CREDITED'
    with core[1]() as s:
        assert s.scalar(select(func.count()).select_from(WalletLedgerTransaction))==1


def test_reserve_clock_sampled_after_lock_wait(core,monkeypatch):
    from app.modules.wallet import receipts
    intent(core); row=deferred(core)
    now=[core[5]]
    core[0].clock=lambda: now[0]
    original=receipts.lock_budget
    def wait(session):
        reserve=original(session)
        now[0]=core[5]+timedelta(seconds=121)
        return reserve
    monkeypatch.setattr(receipts,'lock_budget',wait)
    from app.integrations.tron.finality import TronEvidenceUnavailable
    # The fresh-at-read chain receipt also expires while waiting for this lock;
    # reject the whole retry before changing attribution or ledger state.
    with pytest.raises(TronEvidenceUnavailable):
        retry(core,row['id'])
    with core[1]() as s: assert s.scalar(select(WalletLedgerTransaction)) is None


def test_transaction_sibling_conflict_cannot_be_cleared_by_reserve_refresh(core):
    intent(core)
    evidence=core[2].value
    sibling=replace(evidence.transfers[0],log_index=1,amount_units=11_000_000)
    core[2].value=replace(evidence,transfers=evidence.transfers+(sibling,))
    row=deferred(core)
    core[2].value=replace(evidence,transfers=evidence.transfers+(replace(sibling,amount_units=12_000_000),))
    assert retry(core,row['id'])['status']!='CREDITED'
    with core[1].begin() as s: s.get(RedeemabilityReserve,'global').observed_at=core[5]
    assert retry(core,row['id'])['status']!='CREDITED'
    with core[1]() as s: assert s.scalar(select(WalletLedgerTransaction)) is None
