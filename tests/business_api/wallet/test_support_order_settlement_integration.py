"""Order -> immutable chain proof -> independent approval -> exactly-once credit."""
from dataclasses import replace
from datetime import timedelta
from decimal import Decimal
import pytest
from sqlalchemy import select
from test_deposit_receipts import core  # noqa: F401
from app.core.errors import AppError
from app.modules.ledger.adjustments import AdjustmentWorkflow
from app.modules.ledger.adjustment_models import AdjustmentRequest
from app.modules.ledger.service import LedgerService
from app.modules.recharge.service import RechargeService


def prepared_order(core):
    receipts, factory, adapter, _, _, now = core
    ledger = LedgerService(factory)
    ledger.reserve_policy = 'manual_liquidity'
    clock = [now-timedelta(seconds=1)]
    service = RechargeService(factory, ledger=ledger, wallet_receipts=receipts,
        official_config=receipts.official_config, now=lambda:clock[0])
    order = service.submit(user_id='alice', amount_usdt=Decimal('10'), idempotency_key='order')
    clock[0] = now
    claimed = service.claim_order(request_id=order['id'], actor_id='cs', idempotency_key='claim')
    # Fixture evidence is a real typed adapter proof, never a client amount.
    ms = int(now.timestamp()*1000)
    adapter.value = replace(adapter.value, timestamp_ms=ms,
        solid_head=replace(adapter.value.solid_head,timestamp_ms=ms),
        transfers=tuple(replace(item,timestamp_ms=ms) for item in adapter.value.transfers))
    service.submit_evidence(request_id=order['id'], user_id='alice', txid=adapter.value.txid,
        idempotency_key='user-proof')
    service.verify_order_payment(request_id=order['id'], actor_id='cs', claim_token=claimed['claim_token'],
        txid=adapter.value.txid, log_index=0, idempotency_key='verify')
    service.verify_order_payment(request_id=order['id'], actor_id='cs', claim_token=claimed['claim_token'],
        txid=adapter.value.txid, log_index=0, idempotency_key='reverify')
    return service, order['id'], claimed['claim_token']


def test_pending_approval_then_staff_settlement_retries_credit_once(core):
    service, order_id, token = prepared_order(core)
    prepared = service.prepare_settlement(request_id=order_id, actor_id='cs', claim_token=token,
        final_rate='7.123456', idempotency_key='prepare')
    assert prepared['settlement_status']=='SUBMITTED'
    assert service.ledger.balance('alice')==0
    with pytest.raises(AppError) as denied:
        service.execute_settlement(request_id=order_id, actor_id='cs', claim_token=token,
            idempotency_key='execute', authorization=lambda session:lambda:None)
    assert denied.value.code=='PENDING_APPROVAL'
    workflow = AdjustmentWorkflow(core[1], service.ledger, admin_threshold=Decimal('10000'))
    workflow.finance_review(prepared['adjustment_id'], reviewer_id='independent-finance', approve=True)
    result = service.execute_settlement(request_id=order_id, actor_id='cs', claim_token=token,
        idempotency_key='execute', authorization=lambda session:lambda:None)
    assert result['status']=='CREDITED'
    assert Decimal(result['final_caibi_amount'])==Decimal('71.23')
    for key in ('execute','response-lost'):
        assert service.execute_settlement(request_id=order_id, actor_id='cs', claim_token=token,
            idempotency_key=key, authorization=lambda session:lambda:None)['status']=='CREDITED'
    assert service.ledger.balance('alice')==Decimal('71.23')


def test_final_auth_revoke_rolls_back_adjustment_and_binding(core):
    service, order_id, token = prepared_order(core)
    def revoked_after_work(session):
        def fresh():
            raise AppError(code='PERMISSION_DENIED',message='revoked',status_code=403)
        return fresh
    with pytest.raises(AppError):
        service.prepare_settlement(request_id=order_id,actor_id='cs',claim_token=token,
            final_rate='7',idempotency_key='prepare',authorization=revoked_after_work)
    with core[1]() as session:
        assert session.scalar(select(AdjustmentRequest)) is None
    assert service.ledger.balance('alice')==0


def test_execution_committed_response_lost_recovers_after_proof_expires(core, monkeypatch):
    service, order_id, token = prepared_order(core)
    prepared = service.prepare_settlement(request_id=order_id,actor_id='cs',claim_token=token,
        final_rate='7',idempotency_key='prepare')
    AdjustmentWorkflow(core[1],service.ledger,admin_threshold=Decimal('10000')).finance_review(
        prepared['adjustment_id'],reviewer_id='finance',approve=True)
    complete=service.complete_bound
    def lost(**kwargs): raise RuntimeError('response lost after execution')
    monkeypatch.setattr(service,'complete_bound',lost)
    with pytest.raises(RuntimeError):
        service.execute_settlement(request_id=order_id,actor_id='cs',claim_token=token,
            idempotency_key='execute',authorization=lambda session:lambda:None)
    assert service.ledger.balance('alice')==Decimal('70')
    monkeypatch.setattr(service,'complete_bound',complete)
    service._now=lambda:core[5]+timedelta(seconds=121)
    result=service.execute_settlement(request_id=order_id,actor_id='cs',claim_token=token,
        idempotency_key='execute',authorization=lambda session:lambda:None)
    assert result['status']=='CREDITED'
    assert service.ledger.balance('alice')==Decimal('70')
