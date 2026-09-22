"""Independent second review: durable case/command boundaries."""
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest
from sqlalchemy import select

from test_recharge_binding import env, _execute
from app.core.errors import AppError
from app.core.outbox import OutboxEvent
from app.modules.ledger.adjustment_models import AdjustmentRequest
from app.modules.ledger.adjustments import AdjustmentWorkflow
from app.modules.recharge.models import RechargeCreditBinding, RechargeRequest


def _new_adjustment(factory, ident):
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(AdjustmentRequest(id=ident, user_id="alice", amount=Decimal("50.00"),
            reason_code="RECHARGE_CREDIT", status="SUBMITTED", submitted_by="agent",
            idempotency_key=ident, business_date=now.date(), created_at=now, updated_at=now))


@pytest.mark.parametrize("decision", ["cancel", "reject"])
def test_active_binding_blocks_case_decision(env, decision):
    factory, ledger, recharge = env
    recharge.bind_finance_adjustment(request_id="req-1", adjustment_id="adj-1", actor_id="agent")
    with pytest.raises(AppError):
        if decision == "cancel":
            recharge.cancel(request_id="req-1", user_id="alice")
        else:
            recharge.reject(request_id="req-1", actor_id="finance", reason="not received")


def test_direct_credit_cannot_replace_live_bound_command(env):
    factory, ledger, recharge = env
    recharge.bind_finance_adjustment(request_id="req-1", adjustment_id="adj-1", actor_id="agent")
    _new_adjustment(factory, "adj-2")
    executed = _execute(factory, ledger, "adj-2")
    with pytest.raises(AppError):
        recharge.mark_credited(request_id="req-1", actor_id="finance", adjustment_id="adj-2",
            ledger_transaction_id=executed.ledger_transaction_id, final_caibi_amount="50.00",
            final_rate="1", idempotency_key="wrong-command")


def test_multiple_rejected_commands_keep_durable_history(env):
    factory, ledger, recharge = env
    workflow = AdjustmentWorkflow(factory, ledger, admin_threshold=Decimal("10000"))
    for ident in ("adj-1", "adj-2"):
        if ident == "adj-2":
            _new_adjustment(factory, ident)
        recharge.bind_finance_adjustment(request_id="req-1", adjustment_id=ident, actor_id="agent")
        workflow.finance_review(ident, reviewer_id="finance", approve=False)
        assert recharge.complete_bound(request_id="req-1")["binding_state"] == "FAILED"
    with factory() as session:
        assert len(session.scalars(select(RechargeCreditBinding)).all()) == 2


def test_executed_command_with_unrepresentable_rate_cannot_be_replaced(env):
    factory, ledger, recharge = env
    with factory.begin() as session:
        session.get(RechargeRequest, "req-1").amount_usdt = Decimal("30000")
    recharge.bind_finance_adjustment(request_id="req-1", adjustment_id="adj-1", actor_id="agent")
    _execute(factory, ledger)
    assert ledger.balance("alice") == Decimal("60.00")
    with pytest.raises(AppError):
        recharge.complete_bound(request_id="req-1")
    _new_adjustment(factory, "adj-2")
    with pytest.raises(AppError):
        recharge.bind_finance_adjustment(request_id="req-1", adjustment_id="adj-2", actor_id="agent")


def test_pending_old_case_does_not_starve_executed_recovery(env):
    factory, ledger, recharge = env
    recharge.bind_finance_adjustment(request_id="req-1", adjustment_id="adj-1", actor_id="agent")
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(RechargeRequest(id="req-2", user_id="alice", amount_usdt=Decimal("50"),
            status="SUBMITTED", created_at=now, updated_at=now))
    _new_adjustment(factory, "adj-2")
    recharge.bind_finance_adjustment(request_id="req-2", adjustment_id="adj-2", actor_id="agent")
    with factory.begin() as session:
        session.scalar(select(RechargeCreditBinding).where(
            RechargeCreditBinding.request_id == "req-1")).created_at = now - timedelta(days=1)
    _execute(factory, ledger, "adj-2")
    for _ in range(3):
        recharge.sweep_pending_registrations(limit=1)
    with factory() as session:
        assert session.get(RechargeRequest, "req-2").status == "CREDITED"


def test_binding_failure_emits_transactional_outbox(env):
    factory, ledger, recharge = env
    bound = recharge.bind_finance_adjustment(request_id="req-1", adjustment_id="adj-1", actor_id="agent")
    workflow = AdjustmentWorkflow(factory, ledger, admin_threshold=Decimal("10000"))
    workflow.finance_review("adj-1", reviewer_id="finance", approve=False)
    recharge.sweep_pending_registrations()
    with factory() as session:
        assert session.scalar(select(OutboxEvent.id).where(
            OutboxEvent.aggregate_id == bound["id"],
            OutboxEvent.event_type == "recharge.binding_failed"))


def test_rejected_binding_is_not_reported_as_completed(env):
    factory, ledger, recharge = env
    recharge.bind_finance_adjustment(request_id="req-1", adjustment_id="adj-1", actor_id="agent")
    workflow = AdjustmentWorkflow(factory, ledger, admin_threshold=Decimal("10000"))
    workflow.finance_review("adj-1", reviewer_id="finance", approve=False)
    result = recharge.sweep_pending_registrations()
    assert result["failed"] == 1 and result["completed"] == 0


def test_bound_adjustment_cannot_be_consumed_by_another_case(env):
    factory, ledger, recharge = env
    recharge.bind_finance_adjustment(request_id="req-1", adjustment_id="adj-1", actor_id="agent")
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(RechargeRequest(id="req-2", user_id="alice", amount_usdt=Decimal("50"),
            status="SUBMITTED", created_at=now, updated_at=now))
    executed = _execute(factory, ledger)
    with pytest.raises(AppError):
        recharge.mark_credited(request_id="req-2", actor_id="finance", adjustment_id="adj-1",
            ledger_transaction_id=executed.ledger_transaction_id, final_caibi_amount="50.00",
            final_rate="1", idempotency_key="stolen-command")


def test_binding_preserves_explicit_rate_instead_of_reconstructing_it(env):
    factory, ledger, recharge = env
    recharge.bind_finance_adjustment(request_id="req-1", adjustment_id="adj-1",
        actor_id="agent", final_rate="1.000001")
    view = recharge.list_pending()[0]
    assert view["binding_final_rate"] == "1.000001"
    assert view["binding_final_caibi_amount"] == "50.00"
    _execute(factory, ledger)
    result = recharge.complete_bound(request_id="req-1")
    assert result["final_rate"] == "1.000001"
    with factory() as session:
        binding = session.scalar(select(RechargeCreditBinding))
        assert binding.state == "REGISTERED" and binding.state_active is None


def test_binding_rejects_incorrect_settlement_snapshot(env):
    _, _, recharge = env
    with pytest.raises(AppError) as caught:
        recharge.bind_finance_adjustment(request_id="req-1", adjustment_id="adj-1",
            actor_id="agent", final_rate="2")
    assert caught.value.code == "RECHARGE_SETTLEMENT_MISMATCH"


def test_needs_review_remains_active_and_audited(env):
    factory, ledger, recharge = env
    with factory.begin() as session:
        session.get(RechargeRequest, "req-1").amount_usdt = Decimal("30000")
    bound = recharge.bind_finance_adjustment(request_id="req-1", adjustment_id="adj-1", actor_id="agent")
    _execute(factory, ledger)
    with pytest.raises(AppError):
        recharge.complete_bound(request_id="req-1")
    with pytest.raises(AppError):
        recharge.cancel(request_id="req-1", user_id="alice")
    with factory() as session:
        binding = session.get(RechargeCreditBinding, bound["id"])
        assert binding.state == "NEEDS_REVIEW" and binding.state_active == "1"
        assert session.scalar(select(OutboxEvent.id).where(
            OutboxEvent.aggregate_id == bound["id"],
            OutboxEvent.event_type == "recharge.binding_needs_review"))


def test_negative_adjustment_cannot_be_bound(env):
    factory, _, recharge = env
    with factory.begin() as session:
        session.get(AdjustmentRequest, "adj-1").amount = Decimal("-50.00")
    with pytest.raises(AppError) as caught:
        recharge.bind_finance_adjustment(request_id="req-1", adjustment_id="adj-1", actor_id="agent")
    assert caught.value.code == "RECHARGE_AMOUNT_INVALID"


def test_binding_history_migration_preserves_old_rows_and_allows_more_history(tmp_path):
    import importlib.util
    from pathlib import Path
    from alembic.migration import MigrationContext
    from alembic.operations import Operations
    from sqlalchemy import create_engine, text

    root = Path(__file__).resolve().parents[3]
    engine = create_engine(f"sqlite+pysqlite:///{tmp_path / 'history.db'}")
    with engine.begin() as connection:
        connection.execute(text("CREATE TABLE recharge_requests (id VARCHAR(36) PRIMARY KEY)"))
        connection.execute(text("INSERT INTO recharge_requests VALUES ('req')"))
        with Operations.context(MigrationContext.configure(connection)):
            for version in ("0079_recharge_credit_bindings", "0081_recharge_binding_history"):
                path = root / "services/business-api/migrations/versions" / f"{version}.py"
                spec = importlib.util.spec_from_file_location(version, path)
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                module.upgrade()
                if version.startswith("0079"):
                    connection.execute(text("INSERT INTO recharge_credit_bindings "
                        "(id,request_id,adjustment_id,state,state_active,bound_by,created_at,updated_at) "
                        "VALUES ('old','req','adj1','FAILED','0','actor',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)"))
        assert connection.execute(text("SELECT state_active FROM recharge_credit_bindings WHERE id='old'")).scalar_one() is None
        connection.execute(text("INSERT INTO recharge_credit_bindings "
            "(id,request_id,adjustment_id,state,state_active,bound_by,created_at,updated_at) "
            "VALUES ('new','req','adj2','FAILED',NULL,'actor',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)"))
        assert connection.execute(text("SELECT COUNT(*) FROM recharge_credit_bindings")).scalar_one() == 2
    engine.dispose()
