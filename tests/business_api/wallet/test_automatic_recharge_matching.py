from dataclasses import replace
from datetime import timedelta
from decimal import Decimal
import pytest
from sqlalchemy import select
from test_deposit_receipts import core  # noqa: F401
from app.modules.ledger.service import LedgerService
from app.modules.recharge.service import RechargeService
from app.modules.recharge.models import RechargeRequest
from app.modules.wallet.recharge_receipt_models import RechargeReceiptReservation
from app.modules.wallet.binding_models import WalletBinding
from tasks.recharge_registration import RechargeRegistrationTask


def setup_order(core,amount='10',keys=('one',)):
    receipts,factory,adapter,_,_,now=core
    clock=[now]
    service=RechargeService(factory,ledger=LedgerService(factory),wallet_receipts=receipts,
        official_config=receipts.official_config,now=lambda:clock[0])
    orders=[service.submit(user_id='alice',amount_usdt=amount,idempotency_key=k) for k in keys]
    clock[0]=now+timedelta(seconds=3)
    receipts.ingest(adapter.value.txid,actor_id='observer',defer_credit=True)
    return service,orders,clock


def test_bound_wallet_receipt_matches_order_without_user_or_staff_txid(core):
    service,orders,_=setup_order(core)
    result=service.reconcile_observed_payments()
    assert result['matched']==1
    row=service.list_mine(user_id='alice')[0]
    assert row['id']==orders[0]['id'] and row['payment_verified'] is True
    assert Decimal(row['actual_received_usdt'])==10
    assert row['claimed_by'] is None
    assert service.ledger.balance('alice')==0
    assert service.reconcile_observed_payments()['matched']==0
    with core[1]() as s:assert len(list(s.scalars(select(RechargeReceiptReservation))))==1


def test_two_same_user_amount_orders_are_ambiguous_not_credited(core):
    service,_,_=setup_order(core,keys=('one','two'))
    result=service.reconcile_observed_payments()
    assert result['matched']==0 and result['review']==2
    rows=service.list_mine(user_id='alice')
    assert all(r['processing_stage']=='NEEDS_REVIEW' and not r['payment_verified'] for r in rows)
    assert service.ledger.balance('alice')==0


def test_wrong_amount_is_review_not_false_paid(core):
    service,_,_=setup_order(core,amount='20')
    assert service.reconcile_observed_payments()['matched']==0
    assert service.list_mine(user_id='alice')[0]['processing_stage']=='NEEDS_REVIEW'


def test_payment_before_request_cannot_fund_new_order(core):
    service,orders,clock=setup_order(core)
    with core[1].begin() as s:s.get(RechargeRequest,orders[0]['id']).created_at=clock[0]+timedelta(seconds=1)
    assert service.reconcile_observed_payments()['matched']==0
    assert not service.list_mine(user_id='alice')[0]['payment_verified']


def test_cancelled_order_not_reassigned_to_new_same_amount_order(core):
    service,orders,_=setup_order(core,keys=('one','two'))
    service.cancel(request_id=orders[0]['id'],user_id='alice')
    assert service.reconcile_observed_payments()['matched']==0
    assert not any(r['payment_verified'] for r in service.list_mine(user_id='alice'))


def test_binding_not_effective_at_payment_block_cannot_match(core):
    service,_,_=setup_order(core)
    with core[1].begin() as s:
        binding=s.get(WalletBinding,'binding');binding.barrier_height=102;binding.effective_from_block=103
    assert service.reconcile_observed_payments()['matched']==0
    assert not service.list_mine(user_id='alice')[0]['payment_verified']


def test_expired_order_requires_review_even_with_confirmed_payment(core):
    service,_,clock=setup_order(core)
    clock[0]+=timedelta(hours=2)
    assert service.reconcile_observed_payments()['matched']==0
    assert service.list_mine(user_id='alice')[0]['processing_stage']=='NEEDS_REVIEW'


def test_network_unavailable_leaves_payment_unverified_without_losing_worker_recovery(core,monkeypatch):
    from app.integrations.tron.finality import TronEvidenceUnavailable
    from types import SimpleNamespace
    service,_,_=setup_order(core)
    def unavailable(*args):raise TronEvidenceUnavailable('offline')
    monkeypatch.setattr(core[2],'transaction_evidence',unavailable)
    task=RechargeRegistrationTask(core[1],service.ledger,wallet_runtime=SimpleNamespace(
        receipts=core[0],deposits_enabled=True))
    task._service=service
    result=task.run_batch()
    assert result['matching']['errors']==1
    assert 'expired' in result and 'payout_expired' in result
    assert not service.list_mine(user_id='alice')[0]['payment_verified']
    assert service.ledger.balance('alice')==0
