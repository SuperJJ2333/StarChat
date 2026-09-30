from decimal import Decimal

import pytest
from test_manual_payouts import core, request  # noqa: F401
from test_support_payout import verified, caibi_order, prepare, scoped  # noqa: F401
from app.core.errors import AppError
from app.modules.wallet.manual_payout_models import ManualPayoutOrder
from app.modules.wallet.support_payout import SupportPayoutState


def args(scoped, order):
    _, service, claims = scoped
    view = service.detail(claims=claims['owner'], order_id=order['id'])
    return dict(claims=claims['owner'], order_id=order['id'], reason_code='ADMIN_PAYOUT_CANCEL_REQUESTED',
        idempotency_key='admin-cancel', **verified(service, order['id']))


def test_admin_cancel_unstarted_releases_once(scoped):
    core, service, claims = scoped
    order = request(core)
    body = args(scoped, order)
    result = service.cancel_unstarted(**body)
    assert result['status'] == 'CANCELLED'
    assert service.cancel_unstarted(**body)['status'] == 'CANCELLED'
    assert core[5].balance('HOLD:alice') == Decimal('0')
    assert core[5].balance('alice') == Decimal('1000')


def test_admin_cancel_requires_independent_proof_and_current_versions(scoped):
    core, service, claims = scoped
    order = request(core)
    body = args(scoped, order)
    with pytest.raises(AppError):
        service.cancel_unstarted(**(body | {'owner_authorize': None}))
    service.claim(claims=claims['owner'], order_id=order['id'], idempotency_key='lease')
    with pytest.raises(AppError):
        service.cancel_unstarted(**body)
    assert core[5].balance('HOLD:alice') == Decimal('10')


def test_admin_cancel_prepared_caibi_restores_original_conversion(scoped):
    from app.modules.ledger.service import LedgerService
    core, service, claims = scoped
    order, lease = caibi_order(scoped)
    prepare(scoped, order, lease, rate='8.000000', version=0, key='prepared')
    result = service.cancel_unstarted(**args(scoped, order))
    assert result['status'] == 'CANCELLED'
    assert LedgerService(core[1]).balance('alice') == Decimal('300.00')
    assert core[5].balance('HOLD:alice') == Decimal('0')
    assert core[5].balance('alice') == Decimal('1000')


def test_started_without_hash_only_stops_for_review_no_refund(scoped):
    core, service, claims = scoped
    order = request(core)
    lease = service.claim(claims=claims['owner'], order_id=order['id'], idempotency_key='lease')
    service.begin_payment(claims=claims['owner'], order_id=order['id'], claim_token=lease['claim_token'],
        expected_digest=order['digest'], idempotency_key='begin', **verified(service, order['id']))
    body = args(scoped, order)
    with pytest.raises(AppError):
        service.cancel_unstarted(**body)
    result = service.stop_for_review(**(body | {'reason_code': 'ADMIN_PAYOUT_STOP_FOR_REVIEW'}))
    assert result['status'] == 'UNKNOWN'
    assert core[5].balance('HOLD:alice') == Decimal('10')
    with pytest.raises(AppError):
        service.begin_payment(claims=claims['owner'], order_id=order['id'], claim_token=lease['claim_token'],
            expected_digest=order['digest'], idempotency_key='repeat-payment')


def test_cancel_rejects_existing_candidate_and_staff(scoped):
    core, service, claims = scoped
    order = request(core)
    body = args(scoped, order)
    with pytest.raises(AppError):
        service.cancel_unstarted(**(body | {'claims': claims['bob']}))
    lease = service.claim(claims=claims['owner'], order_id=order['id'], idempotency_key='lease')
    service.begin_payment(claims=claims['owner'], order_id=order['id'], claim_token=lease['claim_token'],
        expected_digest=order['digest'], idempotency_key='begin', **verified(service, order['id']))
    with service.factory.begin() as session:
        row = session.get(ManualPayoutOrder, order['id'])
        row.candidate_txid, row.status = 'a' * 64, 'UNKNOWN'
    with pytest.raises(AppError):
        service.cancel_unstarted(**args(scoped, order))
    assert core[5].balance('HOLD:alice') == Decimal('10')


def test_stop_retains_late_arrival_settlement(scoped):
    from test_manual_payouts import evidence
    core, service, claims = scoped
    order = request(core)
    lease = service.claim(claims=claims['owner'], order_id=order['id'], idempotency_key='late-lease')
    service.begin_payment(claims=claims['owner'], order_id=order['id'], claim_token=lease['claim_token'],
        expected_digest=order['digest'], idempotency_key='late-begin', **verified(service, order['id']))
    service.stop_for_review(**(args(scoped, order) | {'reason_code':'ADMIN_PAYOUT_STOP_FOR_REVIEW'}))
    service.submit_txid(claims=claims['owner'], order_id=order['id'], claim_token=lease['claim_token'],
        txid='a'*64, idempotency_key='late-hash', **verified(service, order['id']))
    core[6].evidence = evidence(core)
    assert core[0].reconcile(order_id=order['id'])['status'] == 'SETTLED'
    assert core[0].reconcile(order_id=order['id'])['status'] == 'SETTLED'
    assert core[5].balance('HOLD:alice') == Decimal('0')
    assert core[5].balance('alice') == Decimal('990')


def test_stop_emits_one_transactional_outbox(scoped):
    from app.core.outbox import OutboxEvent
    from sqlalchemy import select
    core,service,claims=scoped
    order=request(core)
    lease=service.claim(claims=claims['owner'],order_id=order['id'],idempotency_key='stop-lease')
    service.begin_payment(claims=claims['owner'],order_id=order['id'],claim_token=lease['claim_token'],
        expected_digest=order['digest'],idempotency_key='stop-begin',**verified(service,order['id']))
    body=args(scoped,order)|{'reason_code':'ADMIN_PAYOUT_STOP_FOR_REVIEW'}
    service.stop_for_review(**body);service.stop_for_review(**body)
    with core[1]() as session:
        events=session.scalars(select(OutboxEvent).where(OutboxEvent.aggregate_id==order['id'],
            OutboxEvent.event_type=='wallet.support_payout_stopped_for_review')).all()
        assert len(events)==1
        assert events[0].payload['actor_id']=='owner'


def test_exact_hash_retry_recovers_receipt_with_original_version(scoped):
    core,service,claims=scoped
    order=request(core)
    lease=service.claim(claims=claims['owner'],order_id=order['id'],idempotency_key='replay-lease')
    begin=dict(claims=claims['owner'],order_id=order['id'],claim_token=lease['claim_token'],
        expected_digest=order['digest'],idempotency_key='replay-begin',**verified(service,order['id']))
    service.begin_payment(**begin);service.begin_payment(**begin)
    body=dict(claims=claims['owner'],order_id=order['id'],claim_token=lease['claim_token'],
        txid='a'*64,idempotency_key='replay-hash',**verified(service,order['id']))
    first=service.submit_txid(**body)
    assert service.submit_txid(**body)['candidate_txid']==first['candidate_txid']


@pytest.mark.parametrize('after_settlement',[False,True])
def test_selection_retry_resumes_durable_locator(scoped,monkeypatch,after_settlement):
    from test_manual_payouts import evidence
    from app.core.outbox import OutboxEvent
    from sqlalchemy import select
    core,service,claims=scoped
    order=request(core)
    lease=service.claim(claims=claims['owner'],order_id=order['id'],idempotency_key='selection-lease')
    service.begin_payment(claims=claims['owner'],order_id=order['id'],claim_token=lease['claim_token'],
        expected_digest=order['digest'],idempotency_key='selection-begin',**verified(service,order['id']))
    body=dict(claims=claims['owner'],order_id=order['id'],claim_token=lease['claim_token'],
        txid='a'*64,log_index=0,idempotency_key='selection',**verified(service,order['id']))
    core[6].evidence=evidence(core)
    service.discover=lambda **kw:dict(status='COMPLETE',claim_version=body['expected_claim_version'],
        candidates=[dict(txid='a'*64,log_index=0,evidence_status='VERIFIED',timestamp_ms=int(core[2][0].timestamp()*1000))])
    real=core[0].reconcile
    def interrupt(**kw):
        if after_settlement:real(**kw)
        raise RuntimeError('simulated-process-interruption')
    monkeypatch.setattr(core[0],'reconcile',interrupt)
    with pytest.raises(RuntimeError):service.select_discovered(**body)
    monkeypatch.setattr(core[0],'reconcile',real)
    assert service.select_discovered(**body)['status']=='SETTLED'
    assert service.select_discovered(**body)['status']=='SETTLED'
    with pytest.raises(AppError):service.select_discovered(**(body|{'log_index':1}))
    assert core[5].balance('HOLD:alice')==Decimal('0')
    with core[1]() as session:
        events=session.scalars(select(OutboxEvent).where(OutboxEvent.aggregate_id==order['id'],
            OutboxEvent.event_type=='wallet.manual_payout_locator_submitted')).all()
        assert len(events)==1


def test_historical_released_funds_spent_void_is_atomic(scoped):
    from test_manual_payout_void_postgres import void_arguments
    from app.modules.ledger.service import LedgerService
    core,service,claims=scoped
    order,lease=caibi_order(scoped)
    prepared=prepare(scoped,order,lease,rate='7.120000',version=0,key='historical-prepare')
    service.begin_payment(claims=claims['owner'],order_id=order['id'],claim_token=lease['claim_token'],
        expected_digest=prepared['prepared_digest'],expected_preparation_version=1,idempotency_key='historical-begin',
        **verified(service,order['id']))
    # Historical pre-policy adjustment released funds; current API prohibits it.
    with core[1].begin() as session:
        row=session.get(ManualPayoutOrder,order['id']);row.final_receive=Decimal('10');row.status='UNKNOWN'
        core[5].post(entries={'HOLD:alice':Decimal('-10'),'alice':Decimal('10')},actor_id='owner',
            reason_code='MANUAL_PAYOUT_RATE_ADJUSTED',idempotency_key='historical-release',scope='wallet.manual_hold_adjust',session=session)
    available=core[5].balance('alice')
    core[5].post(entries={'alice':-available,'bob':available},actor_id='alice',reason_code='TEST_SPENT',
        idempotency_key='spent-historical-release',scope='test')
    before=(core[5].balance('alice'),core[5].balance('HOLD:alice'),LedgerService(core[1]).balance('alice'))
    with pytest.raises(AppError,match='WALLET_PAYOUT_INSUFFICIENT_BALANCE'):
        core[0].void_unbroadcast(**void_arguments(core,order))
    assert (core[5].balance('alice'),core[5].balance('HOLD:alice'),LedgerService(core[1]).balance('alice'))==before
    assert core[0].status(user_id='alice',order_id=order['id'])['status']=='UNKNOWN'
