"""审计 F03/F04/F05/F07：充值/提现稳定身份、状态机、补偿闭环与分页
——隔离 PostgreSQL 验证（真实事务语义；SQLite 不可替代）。

- F03：低确认→足够确认、同事件重放、新事件同 txid、入账前后崩溃恢复、
      乱序回调 → 最终只入账一次；
- F04：不同用户相同客户端订单号各自唯一订单与分录；同用户同键不同
      金额/地址 → 冲突；回调按全局订单 ID 定位，不能更新他人订单；
- F05：最终失败恢复一次余额；重复失败回调不重复退款；UNKNOWN 不退款；
- F07：游标分页无重复遗漏，页长受限。
"""
import os
from datetime import datetime, timezone
from decimal import Decimal

import pytest
from sqlalchemy import create_engine, select

from app.core.database import Base, create_session_factory
from app.integrations.custody.sandbox import SandboxCustodyProvider
from app.modules.wallet.models import Deposit, WalletLedgerTransaction, Withdrawal
from app.modules.wallet.service import WalletService

PG_URL = os.getenv(
    "AUDIT_PG_URL", "postgresql+psycopg://audit@127.0.0.1:55432/chatflow_audit"
)

pytestmark = pytest.mark.skipif(
    os.getenv("RUN_POSTGRES_TESTS") != "1",
    reason="requires isolated PostgreSQL (RUN_POSTGRES_TESTS=1)",
)


@pytest.fixture()
def wallet():
    engine = create_engine(PG_URL)
    Base.metadata.drop_all(engine)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    provider = SandboxCustodyProvider(secret="audit-secret")
    service = WalletService(factory, provider, confirmation_threshold=12)
    yield service, provider, factory
    engine.dispose()


def _deposit_event(provider, *, event_id, txid, confirmations, user="u1", amount="5.000000"):
    payload = {
        "event_id": event_id, "type": "DEPOSIT_CONFIRMED", "asset": "USDT-TRC20",
        "user_id": user, "amount": amount, "confirmations": confirmations, "txid": txid,
    }
    return payload, provider.sign(payload)


def _withdrawal_event(provider, *, event_id, order_reference, status, txid=None):
    payload = {
        "event_id": event_id, "type": "WITHDRAWAL_STATUS", "asset": "USDT-TRC20",
        "client_order_id": order_reference, "txid": txid or f"chain-{event_id}",
        "status": status, "confirmations": 1,
    }
    return payload, provider.sign(payload)


# ── F03：充值状态机 ──────────────────────────────────────────

def test_f03_low_confirmations_then_threshold_credits_exactly_once(wallet):
    service, provider, factory = wallet
    low, sig = _deposit_event(provider, event_id="e1", txid="tx-1", confirmations=3)
    assert service.handle_deposit_webhook(low, sig) == "PENDING"
    assert service.usdt_balance("u1") == Decimal("0.000000")
    # 同一链上交易的新事件（不同 event_id）：确认数推进 → 入账。
    confirmed, sig2 = _deposit_event(provider, event_id="e2", txid="tx-1", confirmations=15)
    assert service.handle_deposit_webhook(confirmed, sig2) == "CREDITED"
    assert service.usdt_balance("u1") == Decimal("5.000000")
    # 已入账后：同/异事件重放都不再入账。
    replay, sig3 = _deposit_event(provider, event_id="e3", txid="tx-1", confirmations=40)
    assert service.handle_deposit_webhook(replay, sig3) == "CREDITED"
    assert service.usdt_balance("u1") == Decimal("5.000000")
    with factory() as session:
        deposits = session.scalars(select(Deposit)).all()
        credit_txs = session.scalars(select(WalletLedgerTransaction).where(WalletLedgerTransaction.reason_code == "DEPOSIT_CONFIRMED")).all()
    assert len(deposits) == 1, "按 txid 聚合：同链上交易只有一个充值实体"
    assert len(credit_txs) == 1, "最终只入账一次"


def test_f03_event_replay_resumes_incomplete_credit(wallet):
    """同事件重放要能继续完成未入账流程（修复：原来直接返回状态）。

    模拟"入账前崩溃"：手工构造 CONFIRMED 但未入账的中间态，然后重放
    事件 → 补记账并置 CREDITED。
    """
    service, provider, factory = wallet
    event, sig = _deposit_event(provider, event_id="e1", txid="tx-1", confirmations=15)
    # 崩溃模拟：预插一条已过阈值但未入账的充值记录（同 txid）。
    with factory.begin() as session:
        session.add(Deposit(id="d-1", event_id="e1", user_id="u1", txid="tx-1",
                            amount=Decimal("5.000000"), confirmations=15,
                            status="CONFIRMED", created_at=datetime.now(timezone.utc)))
    assert service.handle_deposit_webhook(event, sig) == "CREDITED"
    assert service.usdt_balance("u1") == Decimal("5.000000")


def test_f03_out_of_order_confirmations_never_regress(wallet):
    """乱序回调：确认数只增不减；低确认后到不回退状态。"""
    service, provider, _ = wallet
    confirmed, sig = _deposit_event(provider, event_id="e-late", txid="tx-9", confirmations=20)
    assert service.handle_deposit_webhook(confirmed, sig) == "CREDITED"
    stale, sig2 = _deposit_event(provider, event_id="e-early", txid="tx-9", confirmations=2)
    assert service.handle_deposit_webhook(stale, sig2) == "CREDITED", "已入账不回退"
    assert service.usdt_balance("u1") == Decimal("5.000000")


# ── F04：提现订单唯一范围 ────────────────────────────────────

def _request(service, user, order, amount="2.000000", address="TUser"):
    return service.request_withdrawal(user_id=user, amount=Decimal(amount), address=address, client_order_id=order, reason_code="USER_WITHDRAWAL")


def test_f04_same_client_order_id_across_users_isolated(wallet):
    """两个用户使用相同客户端订单号：各自唯一订单与正确分录。"""
    service, provider, factory = wallet
    service.credit_for_test("u1", Decimal("10.000000"))
    service.credit_for_test("u2", Decimal("10.000000"))
    a = _request(service, "u1", "order-x")
    b = _request(service, "u2", "order-x")
    assert a.id != b.id, "服务端全局唯一 Withdrawal.id 作为订单身份"

    for row, user in ((a, "u1"), (b, "u2")):
        service.finance_approve(row.id, "finance")
        service.submit_to_custody(row.id, "finance")
    # 各自独立扣款（全局执行键 withdraw:{id}）。
    assert service.usdt_balance("u1") == Decimal("8.000000")
    assert service.usdt_balance("u2") == Decimal("8.000000")
    with factory() as session:
        submit_txs = session.scalars(select(WalletLedgerTransaction).where(WalletLedgerTransaction.reason_code == "WITHDRAWAL_SUBMIT")).all()
    assert len(submit_txs) == 2, "执行键按全局订单 ID：跨用户不冲突"


def test_f04_same_user_same_key_different_payload_conflict(wallet):
    service, _, _ = wallet
    _request(service, "u1", "order-y", amount="2.000000")
    with pytest.raises(ValueError, match="different payload"):
        _request(service, "u1", "order-y", amount="3.000000")
    with pytest.raises(ValueError, match="different payload"):
        _request(service, "u1", "order-y", amount="2.000000", address="TOther")


def test_f04_webhook_locates_order_by_global_id_never_other_user(wallet):
    """回调按全局订单 ID 定位；legacy 客户端键仅唯一时兼容，歧义拒绝。"""
    service, provider, factory = wallet
    service.credit_for_test("u1", Decimal("10.000000"))
    service.credit_for_test("u2", Decimal("10.000000"))
    a = _request(service, "u1", "order-z")
    b = _request(service, "u2", "order-z")
    for row in (a, b):
        service.finance_approve(row.id, "finance")
        service.submit_to_custody(row.id, "finance")

    # 新载荷：client_order_id 即全局订单 ID。
    event, sig = _withdrawal_event(provider, event_id="w1", order_reference=a.id, status="FAILED")
    assert service.handle_withdrawal_webhook(event, sig) == "FAILED_COMPENSATED"
    assert service.usdt_balance("u1") == Decimal("10.000000"), "失败恢复余额"
    assert service.usdt_balance("u2") == Decimal("8.000000"), "u2 订单不受影响"

    # legacy 载荷（客户端键）且跨用户歧义 → 拒绝（不能更新错误订单）。
    ambiguous, sig2 = _withdrawal_event(provider, event_id="w2", order_reference="order-z", status="CHAIN_CONFIRMED")
    with pytest.raises(ValueError, match="withdrawal order not found"):
        service.handle_withdrawal_webhook(ambiguous, sig2)


# ── F05：失败补偿闭环 ────────────────────────────────────────

def test_f05_failed_compensates_once_and_repeats_do_not_double_refund(wallet):
    service, provider, factory = wallet
    service.credit_for_test("u1", Decimal("10.000000"))
    row = _request(service, "u1", "order-f")
    service.finance_approve(row.id, "finance")
    service.submit_to_custody(row.id, "finance")
    assert service.usdt_balance("u1") == Decimal("8.000000")

    first, sig = _withdrawal_event(provider, event_id="wf-1", order_reference=row.id, status="FAILED")
    assert service.handle_withdrawal_webhook(first, sig) == "FAILED_COMPENSATED"
    assert service.usdt_balance("u1") == Decimal("10.000000"), "最终失败恢复一次余额"

    # 重复失败回调（不同 event_id、同结果）→ 不重复退款。
    duplicate, sig2 = _withdrawal_event(provider, event_id="wf-2", order_reference=row.id, status="FAILED")
    assert service.handle_withdrawal_webhook(duplicate, sig2) == "FAILED_COMPENSATED"
    assert service.usdt_balance("u1") == Decimal("10.000000")
    # 乱序：失败补偿后的"成功"回调不得改变终态（资金守恒）。
    late, sig3 = _withdrawal_event(provider, event_id="wf-3", order_reference=row.id, status="CHAIN_CONFIRMED")
    assert service.handle_withdrawal_webhook(late, sig3) == "FAILED_COMPENSATED"
    assert service.usdt_balance("u1") == Decimal("10.000000")
    with factory() as session:
        compensations = session.scalars(select(WalletLedgerTransaction).where(WalletLedgerTransaction.reason_code == "WITHDRAWAL_FAILED_COMPENSATION")).all()
    assert len(compensations) == 1, "补偿幂等：只退一次"


def test_f05_unknown_custody_result_never_refunds(wallet):
    """响应丢失但托管实际 UNKNOWN/处理中：绝不退款（先查询再裁决）。"""
    service, provider, _ = wallet
    service.credit_for_test("u1", Decimal("10.000000"))
    row = _request(service, "u1", "order-u")
    service.finance_approve(row.id, "finance")
    service.submit_to_custody(row.id, "finance")
    # 托管侧查无此单（UNKNOWN——如提交请求丢失）。
    provider.withdrawals.pop(row.id, None)
    with pytest.raises(ValueError, match="custody result unknown"):
        service.resolve_unknown_withdrawal(row.id, actor_id="worker")
    assert service.usdt_balance("u1") == Decimal("8.000000"), "UNKNOWN 不退款"


def test_f05_resolve_unknown_failed_compensates_idempotently(wallet):
    service, provider, _ = wallet
    service.credit_for_test("u1", Decimal("10.000000"))
    row = _request(service, "u1", "order-r")
    service.finance_approve(row.id, "finance")
    service.submit_to_custody(row.id, "finance")
    provider.withdrawals[row.id]["status"] = "FAILED"
    result = service.resolve_unknown_withdrawal(row.id, actor_id="worker")
    assert result.status == "FAILED_COMPENSATED"
    assert service.usdt_balance("u1") == Decimal("10.000000")
    # 再次对账处理同一订单：终态不重复补偿。
    again = service.resolve_unknown_withdrawal(row.id, actor_id="worker")
    assert again.status == "FAILED_COMPENSATED"
    assert service.usdt_balance("u1") == Decimal("10.000000")


# ── F07：历史游标分页 ────────────────────────────────────────

def test_f07_history_cursor_pagination_no_dup_or_gap(wallet):
    service, _, _ = wallet
    # 构造交错历史：u1 60 充值 + 60 提现（REQUESTED 不扣款）。
    for i in range(60):
        payload = {"event_id": f"hist-{i}", "type": "DEPOSIT_CONFIRMED", "asset": "USDT-TRC20",
                   "user_id": "u1", "amount": "1.000000", "confirmations": 20, "txid": f"hist-tx-{i}"}
        service.handle_deposit_webhook(payload, service.provider.sign(payload))
        _request(service, "u1", f"hist-order-{i}", amount="0.000001")
    seen: set[str] = set()
    cursor = None
    pages = 0
    while True:
        items, cursor = service.history("u1", None, limit=25, cursor=_parse(cursor))
        assert len(items) <= 25, "页长受限"
        for item in items:
            key = f"{item['kind']}:{item['id']}"
            assert key not in seen, f"翻页重复：{key}"
            seen.add(key)
        pages += 1
        if cursor is None:
            break
        assert pages < 20, "分页不得死循环"
    assert len(seen) == 120, "无重复且无遗漏（60 充值 + 60 提现）"
    assert pages > 1, "确实发生翻页"


def _parse(cursor):
    if cursor is None:
        return None
    from datetime import datetime
    created_at, _, row_id = cursor.partition("|")
    return (datetime.fromisoformat(created_at), row_id)


def test_f07_history_is_user_scoped(wallet):
    service, _, _ = wallet
    payload = {"event_id": "scoped", "type": "DEPOSIT_CONFIRMED", "asset": "USDT-TRC20",
               "user_id": "u1", "amount": "1.000000", "confirmations": 20, "txid": "scoped-tx"}
    service.handle_deposit_webhook(payload, service.provider.sign(payload))
    items, _ = service.history("u2", None)
    assert items == [], "历史按用户隔离"
