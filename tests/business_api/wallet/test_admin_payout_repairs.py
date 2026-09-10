from importlib.util import find_spec

def test_payout_repair_service_exists():
    assert find_spec('app.modules.wallet.repair_payouts') is not None

from types import SimpleNamespace
from dataclasses import replace
from decimal import Decimal
import pytest
from sqlalchemy import select
from test_manual_payouts import core, claim, evidence  # noqa: F401
from app.modules.wallet.repairs import DepositRepairService
from app.modules.wallet.repair_payouts import PayoutReconciliationService
from app.modules.wallet.repair_models import RepairCommand
from app.modules.wallet.manual_payout_models import ManualPayoutOrder
from app.core.errors import AppError

@pytest.fixture
def review(core):
    order=claim(core)
    core[6].evidence=evidence(core)
    core[6].adapter=core[6]
    core[6].clock=core[0].clock
    deposit=DepositRepairService(core[1],receipts=core[6],owner_admin_id='owner',clock_trusted=lambda:True)
    return PayoutReconciliationService(core[1],payouts=core[0],deposits=deposit),order['id']

def payout_preview(review):
    return review[0].preview(actor_id='owner',order_id=review[1],txid='a'*64,log_index=0,
        reason_detail='核实已有转出对应本提现',authorize=lambda s:lambda:None)

def payout_execute(review,p,key='test',operation='operation'):
    return review[0].execute(actor_id='owner',preview_id=p['preview_id'],digest=p['digest'],expected_version=1,
        operation_id=operation,idempotency_key=key,authorize=lambda s:lambda:None)

def test_review_records_existing_candidate_then_standard_reconciler_settles(core,review):
    p=payout_preview(review)
    assert p['blockers']==[]
    result=payout_execute(review,p)
    assert result['status']=='SUBMITTED'
    assert core[5].balance('HOLD:alice')==Decimal('10')
    assert core[0].reconcile(order_id=review[1])['status']=='SETTLED'
    result=review[0].status(actor_id='owner',operation_id='operation',authorize=lambda s:lambda:None)
    assert result['status']=='EXECUTED'
    assert payout_execute(review,p)['operation_id']=='operation'
    assert core[5].balance('HOLD:alice')==0

@pytest.mark.parametrize('change',['direction','amount','stale'])
def test_incompatible_outflow_cannot_submit_candidate(core,review,change):
    transfer=core[6].evidence.transfers[0]
    if change=='direction': transfer=replace(transfer,from_address=transfer.to_address,to_address=transfer.from_address)
    if change=='amount': transfer=replace(transfer,amount_units=11000000)
    if change=='stale':
        from datetime import timedelta
        core[6].evidence=replace(core[6].evidence,observed_at=core[2][0]-timedelta(minutes=10))
    core[6].evidence=replace(core[6].evidence,transfers=(transfer,))
    p=payout_preview(review)
    assert p['blockers']
    with pytest.raises(AppError): payout_execute(review,p)
    with core[1]() as s:
        assert s.get(ManualPayoutOrder,review[1]).candidate_txid is None
        assert s.scalar(select(RepairCommand)) is None
