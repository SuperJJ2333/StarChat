"""审计 F01/F02：统一事务与调账执行幂等——隔离 PostgreSQL 验证。

真实事务与并发结论必须在 PostgreSQL 上得出（SQLite 不可替代）：
- F01：记账后/业务插入前/状态更新前注入异常 → 整体回滚；
      并发同业务键只产生一个单据与一组分录，重试返回相同 ID；
      转账拒收退款 = 本金+手续费一次平衡分录。
- F02：同审批单、两个不同 HTTP 幂等键并发执行 → 只有一笔记账；
      崩溃后重试（模拟）仍只记一次（执行键由审批单 ID 派生）。

运行：需要隔离 PostgreSQL（本仓库审计环境：AUDIT_PG_URL 指向临时
initdb 集群，绝不指向生产）。
"""
import os
import threading
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest
from sqlalchemy import create_engine, event, select

from app.core.database import Base, create_session_factory
from app.modules.ledger.adjustment_models import AdjustmentRequest
from app.modules.ledger.adjustments import AdjustmentWorkflow
from app.modules.ledger.models import LedgerTransaction
from app.modules.ledger.service import LedgerService
from app.modules.redpacket.models import RedPacket
from app.modules.redpacket.service import RedPacketService
from app.modules.transfer.models import ChatTransfer
from app.modules.transfer.service import ChatTransferService

PG_URL = os.getenv(
    "AUDIT_PG_URL", "postgresql+psycopg://audit@127.0.0.1:55432/chatflow_audit"
)

pytestmark = pytest.mark.skipif(
    os.getenv("RUN_POSTGRES_TESTS") != "1",
    reason="requires isolated PostgreSQL (RUN_POSTGRES_TESTS=1)",
)


@pytest.fixture()
def pg():
    engine = create_engine(PG_URL)
    Base.metadata.drop_all(engine)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    yield factory
    engine.dispose()


def _seed(factory, user_id="alice", amount="100.00"):
    LedgerService(factory).adjust(
        user_id=user_id, amount=Decimal(amount), actor_id="finance",
        reason_code="INITIAL_CREDIT", idempotency_key=f"seed-{user_id}",
    )


NOW = datetime.now(timezone.utc)
EXPIRES = NOW + timedelta(hours=24)


# ── F01：异常注入 → 整体回滚 ─────────────────────────────────

def test_f01_redpacket_crash_before_business_insert_rolls_back_everything(pg):
    """记账完成后、红包单据插入前崩溃：账本分录一并回滚。"""
    from sqlalchemy.orm import Session as OrmSession

    _seed(pg)
    service = RedPacketService(pg, LedgerService(pg))

    def crash_before_packet_insert(session, _flush_context, _instances):
        if any(isinstance(obj, RedPacket) for obj in session.new):
            raise RuntimeError("crash before insert")

    event.listen(OrmSession, "before_flush", crash_before_packet_insert)
    try:
        with pytest.raises(RuntimeError, match="crash before insert"):
            service.create_equal(
                sender_id="alice", total=Decimal("10.00"), share_count=2,
                room_id="!room:test", idempotency_key="rp-crash-1", expires_at=EXPIRES,
            )
    finally:
        event.remove(OrmSession, "before_flush", crash_before_packet_insert)

    ledger = LedgerService(pg)
    assert ledger.balance("alice") == Decimal("100.00"), "扣款必须随整体回滚"
    with pg() as session:
        packets = session.scalars(select(RedPacket)).all()
        txs = session.scalars(select(LedgerTransaction)).all()
    assert packets == [], "业务单据未留下"
    create_txs = [t for t in txs if t.scope == "redpacket.create"]
    assert create_txs == [], "账本分录随同一事务回滚"


def test_f01_transfer_crash_between_ledger_and_status_rolls_back(pg, monkeypatch):
    """转账拒收：退款分录记账后、状态更新前崩溃 → 退款整体回滚。"""
    _seed(pg, "alice")
    transfers = ChatTransferService(pg, LedgerService(pg))
    transfer = transfers.create(
        sender_id="alice", receiver_id="bob", amount=Decimal("5.00"),
        idempotency_key="t-crash", expires_at=EXPIRES,
    )

    # 在 ChatTransfer 状态 UPDATE 前注入崩溃（SQLAlchemy before_update 事件）。
    def crash_on_status_update(_mapper, _connection, target):
        if target.status == "DECLINED":
            raise RuntimeError("crash before status update")

    event.listen(ChatTransfer, "before_update", crash_on_status_update)
    ledger = LedgerService(pg)
    balance_before = ledger.balance("alice")
    try:
        with pytest.raises(RuntimeError, match="crash before status update"):
            transfers.decline(transfer.id, user_id="bob", reason_code="USER_DECLINE", idempotency_key="decline-crash")
    finally:
        event.remove(ChatTransfer, "before_update", crash_on_status_update)

    with pg() as session:
        row = session.get(ChatTransfer, transfer.id)
        assert row.status == "PENDING", "业务状态未推进（整体回滚）"
    refund_txs = [t for t in _scopes(pg) if t == "chat_transfer.refund"]
    assert refund_txs == [], "退款分录必须与状态变更同一事务回滚"
    assert ledger.balance("alice") == balance_before


def _scopes(pg):
    with pg() as session:
        return [t.scope for t in session.scalars(select(LedgerTransaction))]


def test_f01_decline_refund_is_single_balanced_entry_with_principal_and_fee(pg):
    """转账拒收：本金+手续费在**一次**平衡分录内退回发送人。"""
    _seed(pg, "alice")
    ledger = LedgerService(pg)
    transfers = ChatTransferService(pg, ledger)
    transfer = transfers.create(
        sender_id="alice", receiver_id="bob", amount=Decimal("5.00"),
        idempotency_key="t-refund", expires_at=EXPIRES,
    )
    sender_before = ledger.balance("alice")
    fee_before = ledger.balance("PLATFORM_FEE")

    transfers.decline(transfer.id, user_id="bob", reason_code="USER_DECLINE", idempotency_key="decline-1")

    # 一次退款分录：sender 收回 本金+手续费，PLATFORM_FEE 退回手续费。
    assert ledger.balance("alice") == sender_before + Decimal("5.00") + Decimal("0.03")
    assert ledger.balance("PLATFORM_FEE") == fee_before - Decimal("0.03")
    refunds = [t for t in _scope_rows(pg) if t.scope == "chat_transfer.refund"]
    assert len(refunds) == 1, "本金与手续费必须一次平衡分录完成"


def _scope_rows(pg):
    with pg() as session:
        return list(session.scalars(select(LedgerTransaction)))


def test_f01_concurrent_same_business_key_single_packet_and_entries(pg):
    """并发同业务键：只产生一个红包与一组分录，重试返回同一 ID。"""
    _seed(pg)
    service = RedPacketService(pg, LedgerService(pg))
    results: list = []
    barrier = threading.Barrier(4)

    def worker(index: int):
        barrier.wait()
        try:
            packet = service.create_equal(
                sender_id="alice", total=Decimal("10.00"), share_count=2,
                room_id="!room:test", idempotency_key=f"rp-conc", expires_at=EXPIRES,
            )
            results.append(packet.id)
        except Exception as error:  # noqa: BLE001 —— 败者回滚后重试收敛
            results.append(error)

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(4)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    # 败者（唯一约束冲突）后重试：最终全部拿到同一业务 ID。
    final = service.create_equal(
        sender_id="alice", total=Decimal("10.00"), share_count=2,
        room_id="!room:test", idempotency_key="rp-conc", expires_at=EXPIRES,
    )
    with pg() as session:
        packets = session.scalars(select(RedPacket)).all()
    assert len(packets) == 1, "并发同业务键只产生一个业务单据"
    create_txs = [t for t in _scope_rows(pg) if t.scope == "redpacket.create"]
    assert len(create_txs) == 1, "并发同业务键只产生一组账本分录"
    assert final.id == packets[0].id


# ── F02：调账单执行幂等 ──────────────────────────────────────

def _approved_adjustment(pg) -> AdjustmentRequest:
    workflow = AdjustmentWorkflow(pg, LedgerService(pg), admin_threshold=Decimal("1000.00"))
    workflow.set_policy("finance", per_transaction=Decimal("100.00"), per_day=Decimal("1000.00"), allowed_users={"bob"})
    request = workflow.submit(actor_id="finance", user_id="bob", amount=Decimal("10.00"), reason_code="AUDIT_TEST", idempotency_key="adj-submit")
    workflow.finance_review(request.id, reviewer_id="reviewer", approve=True)
    return request


def test_f02_concurrent_execute_same_request_different_http_keys_single_ledger(pg):
    """同审批单、两个不同 HTTP 幂等键并发执行 → 只允许一笔账本交易。"""
    request = _approved_adjustment(pg)
    workflow = AdjustmentWorkflow(pg, LedgerService(pg), admin_threshold=Decimal("1000.00"))
    barrier = threading.Barrier(2)

    def worker(http_key: str):
        barrier.wait()
        try:
            workflow.execute(request.id, actor_id="finance", idempotency_key=http_key)
        except Exception:  # noqa: BLE001 —— 行锁串行化后败者看到 EXECUTED
            pass

    threads = [
        threading.Thread(target=worker, args=("http-key-a",)),
        threading.Thread(target=worker, args=("http-key-b",)),
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    adjustments = [t for t in _scope_rows(pg) if t.scope == "ledger.adjustment"]
    assert len(adjustments) == 1, "同一审批单只执行一次（执行键由审批单 ID 派生）"
    with pg() as session:
        row = session.get(AdjustmentRequest, request.id)
        assert row.status == "EXECUTED"
        assert row.ledger_transaction_id == adjustments[0].id


def test_f02_retry_after_completion_returns_same_transaction(pg):
    """执行完成后再以任意 HTTP 键重试：返回同一 EXECUTED 结果，不重复记账。"""
    request = _approved_adjustment(pg)
    workflow = AdjustmentWorkflow(pg, LedgerService(pg), admin_threshold=Decimal("1000.00"))
    first = workflow.execute(request.id, actor_id="finance", idempotency_key="http-1")
    second = workflow.execute(request.id, actor_id="finance", idempotency_key="http-2-different")
    assert second.status == "EXECUTED"
    assert second.ledger_transaction_id == first.ledger_transaction_id
    adjustments = [t for t in _scope_rows(pg) if t.scope == "ledger.adjustment"]
    assert len(adjustments) == 1


def test_f02_crash_between_ledger_and_status_retries_exactly_once(pg):
    """记账后、EXECUTED 标记前崩溃（同事务 → 不可能提交半程）；
    模拟"历史遗留半程"（账本已记、状态未标）后重试：账本幂等键返回
    同一交易并补齐终态，不重复记账。"""
    request = _approved_adjustment(pg)
    ledger = LedgerService(pg)
    # 模拟旧缺陷留下的半程状态：执行键已记账但状态仍 FINANCE_APPROVED。
    tx = ledger.adjust(
        user_id=request.user_id, amount=request.amount, actor_id="finance",
        reason_code=request.reason_code,
        idempotency_key=f"adjustment-execute:{request.id}",
    )
    with pg() as session:
        session.get(AdjustmentRequest, request.id)
    workflow = AdjustmentWorkflow(pg, ledger, admin_threshold=Decimal("1000.00"))
    result = workflow.execute(request.id, actor_id="finance", idempotency_key="any-http-key")
    assert result.status == "EXECUTED"
    assert result.ledger_transaction_id == tx.id
    adjustments = [t for t in _scope_rows(pg) if t.scope == "ledger.adjustment"]
    assert len(adjustments) == 1, "重试不重复记账（账本幂等键去重）"
