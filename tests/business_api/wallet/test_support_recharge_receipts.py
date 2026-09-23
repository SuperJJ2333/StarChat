"""Exercise the real receipt boundary, rather than a fake payment verifier."""
from datetime import timedelta
from dataclasses import replace
import hashlib
import os
from uuid import uuid4
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal

import pytest
from sqlalchemy import select, create_engine, text
from sqlalchemy.engine import make_url
from sqlalchemy.exc import DBAPIError
from sqlalchemy.orm import Session, sessionmaker

from test_deposit_receipts import core, intent  # noqa: F401
from app.core.errors import AppError
from app.modules.fx.models import FxRate
from app.modules.ledger.adjustments import AdjustmentWorkflow
from app.modules.ledger.adjustment_models import AdjustmentRequest
from app.modules.ledger.models import LedgerTransaction
from app.modules.ledger.reserve import RedeemabilityReserve
from app.modules.ledger.service import LedgerService
from app.modules.recharge.models import RechargeRequest, RechargeCreditBinding
from app.modules.wallet.recharge_receipt_models import RechargeReceiptReservation
from app.modules.wallet.manual_deposit_cases import ManualDepositCaseService
from app.modules.wallet.safety import usdt_liability
from app.modules.wallet.models import Deposit, WalletControl


def reserve(core):
    service, factory, adapter, _, receipt_model, now = core
    ms = int(now.timestamp() * 1000)
    adapter.value = replace(adapter.value, timestamp_ms=ms,
        solid_head=replace(adapter.value.solid_head, timestamp_ms=ms),
        transfers=tuple(replace(t, timestamp_ms=ms) for t in adapter.value.transfers))
    proof = service.recharge_evidence(adapter.value.txid)
    with factory.begin() as session:
        result = service.reserve_recharge_payment(session, request_id='order', user_id='alice',
            official_payment={'address': service.official_config.address,
                              'config_version': service.official_config.version},
            created_at=now-timedelta(seconds=1), proof=proof, log_index=0, actor_id='cs', now=now)
    return result


def test_reserved_receipt_cannot_enter_legacy_manual_case(core):
    result = reserve(core)
    service = ManualDepositCaseService(core[1], receipts=core[0], owner_admin_id='owner', clock_trusted=lambda: True)
    with core[1]() as session:
        row = session.get(core[4], result['receipt_id'])
        snapshot = service._snapshot(session, row, None, core[2].value)
        assert 'SUPPORT_RECHARGE_RESERVED' in snapshot['blockers']


def test_reserved_receipt_cannot_transition_via_old_intent(core):
    old = intent(core)
    result = reserve(core)
    with pytest.raises(ValueError, match='reserved'):
        with core[1].begin() as session:
            row = session.get(core[4], result['receipt_id'])
            row.status, row.pending_obligation, row.user_id = 'CREDITED', False, 'alice'
            row.intent_id, row.ledger_transaction_id = old['id'], 'old-credit'


def test_legacy_txid_credit_cannot_be_reserved_as_support_payment(core):
    with core[1].begin() as session:
        session.add(Deposit(id='legacy', event_id='legacy', txid=core[2].value.txid,
            user_id='alice', amount=Decimal('10'), confirmations=20,
            status='CREDITED', created_at=core[5]))
    with pytest.raises(AppError) as error:
        reserve(core)
    assert error.value.code == 'RECHARGE_EVIDENCE_CONFLICT'


@pytest.mark.parametrize('change', ['delete', 'reassign'])
def test_reservation_identity_cannot_be_released_or_reassigned(core, change):
    result = reserve(core)
    with pytest.raises(ValueError, match='immutable'):
        with core[1].begin() as session:
            reservation = session.get(RechargeReceiptReservation, result['receipt_id'])
            if change == 'delete': session.delete(reservation)
            else: reservation.request_id = 'another-order'


def test_transactional_adjustment_submission_rolls_back_with_order(core):
    workflow = AdjustmentWorkflow(core[1], LedgerService(core[1]), admin_threshold=Decimal('1000'))
    workflow.set_policy('cs', per_transaction=Decimal('100'), per_day=Decimal('1000'), allowed_users={'alice'})
    with pytest.raises(RuntimeError, match='bind failed'):
        with core[1].begin() as session:
            workflow.submit(actor_id='cs', user_id='alice', amount=Decimal('70'),
                reason_code='SUPPORT_RECHARGE', idempotency_key='atomic', session=session)
            raise RuntimeError('bind failed')
    with core[1]() as session:
        assert session.scalar(select(AdjustmentRequest)) is None


def test_support_submission_is_order_scoped_without_generic_adjustment_policy(core):
    result = reserve(core)
    factory, now = core[1], core[5]
    workflow = AdjustmentWorkflow(factory, LedgerService(factory), admin_threshold=Decimal('1000'))
    with factory.begin() as session:
        session.add(RechargeRequest(id='order', user_id='alice', amount_usdt=Decimal('10'), status='SUBMITTED',
            created_at=now, updated_at=now, expires_at=now+timedelta(hours=2),
            claimed_by='cs', claim_token_hash=hashlib.sha256(b'token').hexdigest(),
            claim_expires_at=now+timedelta(minutes=5), payment_verified_at=now,
            receipt_id=result['receipt_id'], actual_received_usdt=Decimal('10')))
    with factory.begin() as session:
        request = workflow.submit_support_recharge(session=session, request_id='order', actor_id='cs',
            claim_token='token', final_rate=Decimal('7'), idempotency_key='settle')
        assert (request.user_id, request.amount, request.status, request.reason_code) == (
            'alice', Decimal('70'), 'SUBMITTED', 'RECHARGE_CREDIT')
    assert workflow.ledger.balance('alice') == 0
    with pytest.raises(AppError):
        with factory.begin() as session:
            workflow.submit_support_recharge(session=session, request_id='order', actor_id='other',
                claim_token='token', final_rate=Decimal('7'), idempotency_key='bad')
    workflow.finance_review(request.id, reviewer_id='finance', approve=True)
    with pytest.raises(AppError):
        workflow.execute(request.id, actor_id='cs', idempotency_key='cannot-execute-unbound')


def prepared_execution(core):
    result = reserve(core)
    factory, now = core[1], core[5]
    ledger = LedgerService(factory)
    workflow = AdjustmentWorkflow(factory, ledger, admin_threshold=Decimal('1000'))
    workflow.set_policy('cs', per_transaction=Decimal('100'), per_day=Decimal('1000'), allowed_users={'alice'})
    adjustment = workflow.submit(actor_id='cs', user_id='alice', amount=Decimal('70'),
        reason_code='SUPPORT_RECHARGE', idempotency_key='one')
    with factory.begin() as session:
        session.add(FxRate(pair='USD/CNY', rate=Decimal('7'), fetched_at=now, expires_at=now+timedelta(hours=1)))
        session.add(RechargeRequest(id='order', user_id='alice', amount_usdt=Decimal('10'), status='SUBMITTED',
            created_at=now, updated_at=now, expires_at=now+timedelta(hours=2),
            claimed_by='cs', claim_token_hash=hashlib.sha256(b'token').hexdigest(), claim_expires_at=now+timedelta(minutes=5), payment_verified_at=now,
            receipt_id=result['receipt_id'], actual_received_usdt=Decimal('10')))
        session.flush()
        session.add(RechargeCreditBinding(id='binding', request_id='order', adjustment_id=adjustment.id,
            state='BOUND', state_active='1', final_rate=Decimal('7'), final_caibi_amount=Decimal('70'),
            bound_by='cs', created_at=now, updated_at=now))
    workflow.finance_review(adjustment.id, reviewer_id='finance', approve=True)
    return workflow, adjustment, result


def test_verified_receipt_consumption_and_ledger_execute_are_once(core):
    workflow, adjustment, result = prepared_execution(core)
    factory, ledger = core[1], workflow.ledger
    first = workflow.execute(adjustment.id, actor_id='cs', idempotency_key='execute-one', support_claim_token='token', support_authorization=lambda session: lambda: None)
    again = workflow.execute(adjustment.id, actor_id='cs', idempotency_key='different-http-key', support_claim_token='token', support_authorization=lambda session: lambda: None)
    assert first.ledger_transaction_id == again.ledger_transaction_id
    assert ledger.balance('alice') == Decimal('70')
    with factory() as session:
        row = session.get(core[4], result['receipt_id'])
        assert row.status == 'CREDITED' and row.pending_obligation is False
        assert row.caibi_ledger_transaction_id == first.ledger_transaction_id
        assert session.get(RechargeReceiptReservation, row.id).state == 'CONSUMED'
        assert session.get(RedeemabilityReserve, 'global').usdt_liability == 0
        assert usdt_liability(session) == 0
        assert len(list(session.scalars(select(LedgerTransaction)))) == 1
    with pytest.raises(AppError): reserve(core)


def test_managed_execution_rejects_legacy_admin_route_even_for_claim_owner(core):
    workflow, adjustment, _ = prepared_execution(core)
    with pytest.raises(AppError) as error:
        workflow.execute(adjustment.id, actor_id='cs', idempotency_key='legacy-route')
    assert error.value.code == 'RECHARGE_EXECUTION_AUTHORIZATION_REQUIRED'
    assert workflow.ledger.balance('alice') == 0


def test_support_request_cannot_approve_itself(core):
    workflow, adjustment, _ = prepared_execution(core)
    with core[1].begin() as session:
        row = session.get(AdjustmentRequest, adjustment.id)
        row.status = 'SUBMITTED'
        row.idempotency_key = 'support-recharge:self-review'
    with pytest.raises(AppError) as error:
        workflow.admin_review(adjustment.id, reviewer_id='cs', approve=True)
    assert error.value.code == 'RECHARGE_INDEPENDENT_APPROVAL_REQUIRED'


def test_managed_order_requires_independent_approval_even_for_generic_adjustment(core):
    workflow, adjustment, _ = prepared_execution(core)
    with core[1].begin() as session:
        session.get(AdjustmentRequest, adjustment.id).finance_reviewer_id = 'cs'
    with pytest.raises(AppError) as error:
        workflow.execute(adjustment.id, actor_id='cs', idempotency_key='self-approved',
            support_claim_token='token', support_authorization=lambda session: lambda: None)
    assert error.value.code == 'RECHARGE_INDEPENDENT_APPROVAL_REQUIRED'


def test_expired_authorization_rolls_back_posted_ledger(core):
    workflow, adjustment, result = prepared_execution(core)
    def authorize(session):
        def fresh():
            raise AppError(code='SUPPORT_AUTH_EXPIRED', message='expired', status_code=403)
        return fresh
    with pytest.raises(AppError):
        workflow.execute(adjustment.id, actor_id='cs', idempotency_key='expired',
            support_claim_token='token', support_authorization=authorize)
    assert workflow.ledger.balance('alice') == 0
    with core[1]() as session:
        assert session.get(RechargeReceiptReservation, result['receipt_id']).state == 'RESERVED'


def test_support_approval_emits_audit_and_outbox(core):
    from app.modules.audit.models import AuditEvent
    from app.core.outbox import OutboxEvent
    workflow, adjustment, _ = prepared_execution(core)
    with core[1].begin() as session:
        row = session.get(AdjustmentRequest, adjustment.id)
        row.status = 'SUBMITTED'
        row.idempotency_key = 'support-recharge:review'
    workflow.admin_review(adjustment.id, reviewer_id='independent-admin', approve=True)
    with core[1]() as session:
        audit = session.scalar(select(AuditEvent).where(AuditEvent.action == 'recharge.adjustment_reviewed'))
        assert audit.actor_id == 'independent-admin'
        assert audit.after_data == {'decision': 'APPROVED'}
        assert session.scalar(select(OutboxEvent).where(OutboxEvent.event_type == 'recharge.adjustment_reviewed')) is not None


def test_failure_after_ledger_post_rolls_back_receipt_and_reserve(core, monkeypatch):
    workflow, adjustment, result = prepared_execution(core)
    from app.modules.recharge import execution
    def fail(*args, **kwargs): raise RuntimeError('receipt consumption unavailable')
    monkeypatch.setattr(execution, 'finish_adjustment_execution', fail)
    # AdjustmentWorkflow imports this hook directly; inject at the actual caller.
    from app.modules.ledger import adjustments
    monkeypatch.setattr(adjustments, 'finish_adjustment_execution', fail)
    with pytest.raises(RuntimeError, match='receipt consumption unavailable'):
        workflow.execute(adjustment.id, actor_id='cs', idempotency_key='failure', support_claim_token='token', support_authorization=lambda session: lambda: None)
    assert workflow.ledger.balance('alice') == 0
    with core[1]() as session:
        assert session.get(core[4], result['receipt_id']).pending_obligation is True
        assert session.get(RechargeReceiptReservation, result['receipt_id']).state == 'RESERVED'
        assert session.get(RedeemabilityReserve, 'global').usdt_liability == Decimal('10')
        assert session.get(AdjustmentRequest, adjustment.id).status == 'FINANCE_APPROVED'


@pytest.mark.skipif(not os.getenv('SUPPORT_RECEIPT_TEST_DATABASE_URL'), reason='isolated PostgreSQL URL required')
def test_postgres_migrated_guards_and_two_sessions_execute_once(monkeypatch):
    """Use an isolated per-run schema, retaining it for review; no shared DB drops."""
    from alembic import command
    from alembic.config import Config
    from pathlib import Path
    import test_deposit_receipts as fixture_module
    url = make_url(os.environ['SUPPORT_RECEIPT_TEST_DATABASE_URL'])
    schema = 'receipt_' + uuid4().hex
    bootstrap = create_engine(url, isolation_level='AUTOCOMMIT')
    with bootstrap.connect() as connection:
        connection.execute(text('CREATE SCHEMA ' + schema))
    bootstrap.dispose()
    scoped_url = url.update_query_dict({'options': '-csearch_path=' + schema})
    monkeypatch.setenv('BUSINESS_DATABASE_URL', scoped_url.render_as_string(hide_password=False))
    config = Config('services/business-api/alembic.ini')
    config.set_main_option('path_separator', 'os')
    config.set_main_option('script_location', str(Path('services/business-api/migrations').resolve()))
    command.upgrade(config, 'head')
    engine = create_engine(scoped_url)
    monkeypatch.setattr(fixture_module, 'create_engine', lambda *args, **kwargs: engine)
    class MigrationSeedSession(Session):
        def add(self, instance, *, _warn=True):
            if isinstance(instance, (WalletControl, RedeemabilityReserve)):
                existing = self.get(type(instance), instance.id)
                if existing is not None:
                    for name, value in vars(instance).items():
                        if not name.startswith('_'): setattr(existing, name, value)
                    return
            super().add(instance, _warn=_warn)
    monkeypatch.setattr(fixture_module, 'create_session_factory', lambda engine:
        sessionmaker(engine, class_=MigrationSeedSession, expire_on_commit=False))
    generator = fixture_module.core.__wrapped__()
    core = next(generator)
    try:
        old = intent(core)
        workflow, adjustment, result = prepared_execution(core)
        with pytest.raises(DBAPIError, match='reserved for support recharge'):
            with engine.begin() as connection:
                connection.execute(text("UPDATE wallet_deposit_receipts SET status='CREDITED', pending_obligation=false, user_id='alice', intent_id=:intent, ledger_transaction_id='old-credit' WHERE id=:id"), {'intent':old['id'],'id':result['receipt_id']})
        with pytest.raises(DBAPIError, match='immutable support receipt reservation'):
            with engine.begin() as connection:
                connection.execute(text('DELETE FROM wallet_recharge_receipt_reservations WHERE receipt_id=:id'), {'id':result['receipt_id']})
        def execute(index):
            return workflow.execute(adjustment.id, actor_id='cs', idempotency_key='concurrent-'+str(index), support_claim_token='token', support_authorization=lambda session: lambda: None).ledger_transaction_id
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(execute, [1, 2]))
        assert results[0] == results[1]
        assert workflow.ledger.balance('alice') == Decimal('70')
        with core[1]() as session:
            assert session.get(core[4],result['receipt_id']).caibi_ledger_transaction_id == results[0]
            assert session.get(RedeemabilityReserve,'global').usdt_liability == 0
    finally:
        generator.close()
