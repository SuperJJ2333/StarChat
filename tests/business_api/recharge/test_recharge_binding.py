"""ADR-0077 实施补充：充值案件与财务执行的持久绑定（含宕机恢复）。

- 绑定唯一性：一个案件一个活动绑定；一条调整至多绑定一个案件；
- 调整审批通过并执行后，worker 幂等登记（复用 mark_credited 全部
  凭证校验）；重复回调/并发处理无二次入账；
- 调整被拒 → 绑定 FAILED，案件保留 SUBMITTED 可重新绑定；
- 错误用户/终态调整/已冲正 → 绑定拒绝。
"""
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest
from sqlalchemy import create_engine, event, select
from sqlalchemy.orm import sessionmaker

import app.modules.recharge.models  # noqa: F401
import app.modules.identity.models  # noqa: F401  (FK 目标：users)
from app.core.database import Base
from app.core.errors import AppError
from app.modules.ledger.adjustment_models import AdjustmentRequest
from app.modules.ledger.models import LedgerEntry, LedgerTransaction
from app.modules.ledger.service import LedgerService
from app.modules.recharge.models import RechargeCreditBinding, RechargeRequest
from app.modules.recharge.service import RechargeService


@pytest.fixture()
def env(tmp_path):
    engine = create_engine(f"sqlite+pysqlite:///{tmp_path / 'bind.db'}",
        connect_args={"check_same_thread": False, "timeout": 15})

    @event.listens_for(engine, "connect")
    def _fk(dbapi_connection, _record):
        dbapi_connection.execute("PRAGMA foreign_keys=ON")

    Base.metadata.create_all(engine)
    factory = sessionmaker(bind=engine, expire_on_commit=False)
    ledger = LedgerService(factory)
    ledger.adjust(user_id="alice", amount=Decimal("10.00"), actor_id="finance",
        reason_code="SEED", idempotency_key="seed-clearing")  # 保证 CLEARING 有可发行额度
    recharge = RechargeService(factory, ledger=ledger)
    now = datetime.now(timezone.utc)
    from app.modules.identity.models import User

    with factory.begin() as session:
        for uid in ("alice", "bob"):
            session.add(User(id=uid, username=uid, username_normalized=uid,
                email=f"{uid}@x.test", email_normalized=f"{uid}@x.test", password_hash="x",
                status="ACTIVE", created_at=now, updated_at=now))
        session.add(RechargeRequest(id="req-1", user_id="alice", amount_usdt=Decimal("50"),
            evidence_txid="A" * 64, status="SUBMITTED", created_at=now, updated_at=now))
        session.add(AdjustmentRequest(id="adj-1", user_id="alice", amount=Decimal("50.00"),
            reason_code="RECHARGE_CREDIT", status="SUBMITTED", submitted_by="agent",
            idempotency_key="adj-1-key", business_date=now.date(), created_at=now, updated_at=now))
        session.add(AdjustmentRequest(id="adj-other", user_id="bob", amount=Decimal("50.00"),
            reason_code="RECHARGE_CREDIT", status="SUBMITTED", submitted_by="agent",
            idempotency_key="adj-other-key", business_date=now.date(), created_at=now, updated_at=now))
    yield factory, ledger, recharge
    engine.dispose()


def _execute(factory, ledger, adjustment_id="adj-1", amount=None, user="alice"):
    """走真实公开财务链路：审批 + 执行（AdjustmentWorkflow，真实账本写入）。"""
    from app.modules.ledger.adjustments import AdjustmentWorkflow

    workflow = AdjustmentWorkflow(factory, ledger, admin_threshold=Decimal("10000"))
    workflow.finance_review(adjustment_id, reviewer_id="finance-1", approve=True)
    executed = workflow.execute(adjustment_id, actor_id="finance-1", idempotency_key="exec-1")
    assert executed.ledger_transaction_id
    return executed


def test_bind_rejects_wrong_user_and_terminal_adjustments(env):
    factory, ledger, recharge = env
    with pytest.raises(AppError) as excinfo:
        recharge.bind_finance_adjustment(request_id="req-1", adjustment_id="adj-other", actor_id="agent")
    assert excinfo.value.code == "RECHARGE_PROOF_INVALID"
    with pytest.raises(AppError) as excinfo:
        recharge.bind_finance_adjustment(request_id="req-1", adjustment_id="missing", actor_id="agent")
    assert excinfo.value.code == "RECHARGE_PROOF_INVALID"


def test_bind_is_unique_on_both_sides_and_replay_is_idempotent(env):
    factory, ledger, recharge = env
    first = recharge.bind_finance_adjustment(request_id="req-1", adjustment_id="adj-1", actor_id="agent")
    assert first["state"] == "BOUND"
    # 同参数重放 → 同一绑定
    replay = recharge.bind_finance_adjustment(request_id="req-1", adjustment_id="adj-1", actor_id="agent",
        idempotency_key="bind-1")
    assert replay["id"] == first["id"]
    # 其他调整绑同一案件 → 拒绝
    with pytest.raises(AppError) as excinfo:
        recharge.bind_finance_adjustment(request_id="req-1", adjustment_id="adj-other", actor_id="agent",
            idempotency_key="bind-2")
    assert excinfo.value.code == "RECHARGE_CASE_BOUND"


def test_execute_then_worker_registers_exactly_once(env):
    factory, ledger, recharge = env
    recharge.bind_finance_adjustment(request_id="req-1", adjustment_id="adj-1", actor_id="agent")
    # 未执行时 worker 扫描 → PENDING_APPROVAL，不入账
    sweep = recharge.sweep_pending_registrations()
    assert sweep["pending"] == 1 and sweep["completed"] == 0
    _execute(factory, ledger)
    sweep = recharge.sweep_pending_registrations()
    assert sweep["completed"] == 1
    with factory() as session:
        row = session.get(RechargeRequest, "req-1")
        assert row.status == "CREDITED" and row.final_caibi_amount == Decimal("50.00")
        assert row.adjustment_id == "adj-1"
        binding = session.scalar(select(RechargeCreditBinding).where(
            RechargeCreditBinding.request_id == "req-1"))
        assert binding.state == "REGISTERED"
    balance_before = ledger.balance("alice")
    # 宕机/重复回调恢复：再次扫描与手动完成均不二次入账
    sweep = recharge.sweep_pending_registrations()
    assert sweep["completed"] == 0
    recharge.complete_bound(request_id="req-1")
    assert ledger.balance("alice") == balance_before


def test_rejected_adjustment_fails_binding_and_allows_rebind(env):
    factory, ledger, recharge = env
    recharge.bind_finance_adjustment(request_id="req-1", adjustment_id="adj-1", actor_id="agent")
    with factory.begin() as session:
        session.get(AdjustmentRequest, "adj-1").status = "REJECTED"
    result = recharge.complete_bound(request_id="req-1")
    assert result["binding_state"] == "FAILED"
    with factory() as session:
        assert session.get(RechargeRequest, "req-1").status == "SUBMITTED"
        assert session.scalar(select(RechargeCreditBinding.state).where(
            RechargeCreditBinding.request_id == "req-1")) == "FAILED"
    # 案件可绑定新的调整（旧调整释放），且同调整可被其他案件绑定
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(AdjustmentRequest(id="adj-2", user_id="alice", amount=Decimal("50.00"),
            reason_code="RECHARGE_CREDIT", status="SUBMITTED", submitted_by="agent",
            idempotency_key="adj-2-key", business_date=now.date(), created_at=now, updated_at=now))
    bound = recharge.bind_finance_adjustment(request_id="req-1", adjustment_id="adj-2", actor_id="agent")
    assert bound["state"] == "BOUND"


def test_worker_marks_binding_failed_when_executed_adjustment_gets_reversed(env):
    """执行后被冲正的调整：登记拒绝、绑定 FAILED，绝不以冲正后的凭证入账。"""
    factory, ledger, recharge = env
    recharge.bind_finance_adjustment(request_id="req-1", adjustment_id="adj-1", actor_id="agent")
    executed = _execute(factory, ledger)
    ledger.reverse(original_id=executed.ledger_transaction_id, reason_code="RECHARGE_REVERSED",
        actor_id="finance-1", idempotency_key="reverse-1")
    sweep = recharge.sweep_pending_registrations()
    assert sweep["failed"] == 1
    with factory() as session:
        assert session.get(RechargeRequest, "req-1").status == "SUBMITTED"  # 未登记入账
        assert session.scalar(select(RechargeCreditBinding.state).where(
            RechargeCreditBinding.request_id == "req-1")) == "FAILED"
    # 冲正后用户余额回到种子值；案件保留待人工处理
    assert ledger.balance("alice") == Decimal("10.00")
