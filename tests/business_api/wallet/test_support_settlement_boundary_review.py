"""Independent integration review of execution and registration boundaries."""
from decimal import Decimal
import pytest
from test_deposit_receipts import core  # noqa: F401
from test_support_order_settlement_integration import prepared_order
from app.core.errors import AppError
from app.modules.ledger.adjustments import AdjustmentWorkflow
from app.modules.recharge.service import RechargeService


def approved_order(core):
    service, order_id, token = prepared_order(core)
    prepared = service.prepare_settlement(request_id=order_id, actor_id='cs', claim_token=token,
        final_rate='7', idempotency_key='prepare-review')
    AdjustmentWorkflow(core[1], service.ledger, admin_threshold=Decimal('10000')).finance_review(
        prepared['adjustment_id'], reviewer_id='independent', approve=True)
    return service, order_id, token


def test_review_claim_requires_new_payment_verification_before_execution(core):
    service, order_id, _ = approved_order(core)
    reviewed = service.claim_order(request_id=order_id, actor_id='cs', review=True,
        reason='independent review', idempotency_key='review-new-claim')
    assert not reviewed['payment_verified']
    with pytest.raises(AppError):
        service.execute_settlement(request_id=order_id, actor_id='cs', claim_token=reviewed['claim_token'],
            idempotency_key='execute-after-review', authorization=lambda session: lambda: None)
    assert service.ledger.balance('alice') == 0


def test_committed_execution_registration_failure_recovers_with_worker(core, monkeypatch):
    service, order_id, token = approved_order(core)
    def unavailable(**kwargs):
        raise RuntimeError('registration unavailable')
    monkeypatch.setattr(service, 'complete_bound', unavailable)
    with pytest.raises(RuntimeError, match='registration unavailable'):
        service.execute_settlement(request_id=order_id, actor_id='cs', claim_token=token,
            idempotency_key='lost-response', authorization=lambda session: lambda: None)
    assert service.ledger.balance('alice') == Decimal('70')
    worker_service = RechargeService(core[1], ledger=service.ledger)
    assert worker_service.sweep_pending_registrations()['completed'] == 1
    assert worker_service.sweep_pending_registrations()['scanned'] == 0
    assert service.ledger.balance('alice') == Decimal('70')


def test_execution_final_authorization_failure_rolls_back_financial_effect(core):
    service, order_id, token = approved_order(core)
    def authorization(session):
        def fresh():
            raise AppError(code='PERMISSION_DENIED', message='revoked', status_code=403)
        return fresh
    with pytest.raises(AppError):
        service.execute_settlement(request_id=order_id, actor_id='cs', claim_token=token,
            idempotency_key='revoke', authorization=authorization)
    assert service.ledger.balance('alice') == 0
