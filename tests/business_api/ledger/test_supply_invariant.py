"""点钻总量不变式：发行后任何支付/转账/手续费都不改变系统总发行量。

验收标准（产品规则的可执行化）：
- 每笔账务是平衡分录：任一 LedgerTransaction 的全部科目金额之和恒为 0；
- 全系统所有科目余额之和恒等于累计发行量（测试中为 1000.00）；
- 手续费进入官方平台科目 PLATFORM_FEE 且金额可追溯（每笔交易携带
  reason_code、审计事件与 Outbox 事件）；
- 红包链路不产生手续费科目变动。
"""
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.pool import StaticPool

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.core.outbox import OutboxEvent
from app.modules.audit.models import AuditEvent
from app.modules.ledger.models import LedgerEntry, LedgerTransaction
from app.modules.ledger.service import LedgerService
from app.modules.redpacket.service import RedPacketService
from app.modules.transfer.service import ChatTransferService, transfer_fee

ISSUED_TOTAL = Decimal("1000.00")


@pytest.fixture()
def context():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    settings = Settings(_env_file=None, environment="test", database_url="sqlite+pysqlite:///:memory:", redis_url="redis://localhost:6379/15", jwt_secret="r" * 32, totp_issuer="六合通")
    ledger = LedgerService(factory)
    now = datetime.now(timezone.utc)
    ledger.adjust(user_id="alice", amount=Decimal("400.00"), actor_id="issuance", reason_code="INITIAL_ISSUE", idempotency_key="issue-a")
    ledger.adjust(user_id="bravo", amount=Decimal("600.00"), actor_id="issuance", reason_code="INITIAL_ISSUE", idempotency_key="issue-b")
    yield factory, ledger, settings, now
    engine.dispose()


def circulating_total(factory) -> Decimal:
    """流通总量 = 全部账户余额之和，扣除发行镜像科目 PLATFORM_CLEARING。

    复式账本下每笔交易平衡，故"流通总量"（用户钱包 + 红包/转账托管 +
    官方手续费钱包）恒等于累计发行量；PLATFORM_CLEARING 恒为其负镜像。
    """
    with factory() as session:
        rows = session.scalars(
            select(LedgerEntry.amount).where(
                LedgerEntry.asset == "CAIBI",
                LedgerEntry.account_id.not_like("PLATFORM_CLEARING%"),
            )
        )
        return sum((Decimal(v) for v in rows), Decimal("0.00"))


def platform_balance(factory, account: str) -> Decimal:
    from sqlalchemy import func

    with factory() as session:
        value = session.scalar(
            select(func.coalesce(func.sum(LedgerEntry.amount), 0)).where(
                LedgerEntry.account_id == account,
                LedgerEntry.asset == "CAIBI",
            )
        )
        return Decimal(value)


def assert_every_transaction_balanced(factory):
    with factory() as session:
        transactions = session.scalars(select(LedgerTransaction)).all()
        assert transactions
        for tx in transactions:
            assert tx.reason_code
            total = sum((Decimal(entry.amount) for entry in tx.entries), Decimal("0.00"))
            assert total == Decimal("0.00"), f"{tx.id} ({tx.reason_code}) unbalanced: {total}"
    return len(transactions)


def assert_traceability(factory, expected_posts: int):
    with factory() as session:
        audits = session.scalars(select(AuditEvent).where(AuditEvent.action == "ledger.post")).all()
        outbox = session.scalars(select(OutboxEvent).where(OutboxEvent.event_type == "ledger.posted")).all()
    assert len(audits) >= expected_posts
    assert len(outbox) >= expected_posts


def test_supply_stays_constant_through_red_packets_and_transfers(context):
    factory, ledger, settings, now = context
    assert circulating_total(factory) == ISSUED_TOTAL
    assert platform_balance(factory, "PLATFORM_CLEARING") == -ISSUED_TOTAL

    # 红包：alice 发 10.00 拼手气红包（无手续费），bravo 领取一份。
    from app.modules.redpacket.membership import StaticRoomMembershipAuthority
    _membership = StaticRoomMembershipAuthority()
    _membership.set_members("!room:test", {"bravo"})
    packets = RedPacketService(factory, ledger, max_total=Decimal("20000.00"), room_membership=_membership)
    packet = packets.create_random(
        sender_id="alice",
        total=Decimal("10.00"),
        share_count=2,
        room_id="!room:test",
        idempotency_key="rp-1",
        expires_at=now + timedelta(hours=24),
    )
    assert circulating_total(factory) == ISSUED_TOTAL
    assert platform_balance(factory, "PLATFORM_CLEARING") == -ISSUED_TOTAL
    share = packets.claim(packet.id, user_id="bravo", idempotency_key="claim-1")
    assert circulating_total(factory) == ISSUED_TOTAL
    assert platform_balance(factory, "PLATFORM_CLEARING") == -ISSUED_TOTAL

    # 转账：alice → bravo 5.00，手续费 0.03（0.5%，最低 0.01 分保底）。
    transfers = ChatTransferService(factory, ledger)
    fee = transfer_fee(Decimal("5.00"))
    assert fee == Decimal("0.03")
    transfer = transfers.create(
        sender_id="alice",
        receiver_id="bravo",
        amount=Decimal("5.00"),
        idempotency_key="tx-1",
        expires_at=now + timedelta(minutes=30),
    )
    assert transfer.fee == fee
    assert circulating_total(factory) == ISSUED_TOTAL
    assert platform_balance(factory, "PLATFORM_CLEARING") == -ISSUED_TOTAL
    transfers.accept(transfer.id, user_id="bravo", idempotency_key="acc-1")
    assert circulating_total(factory) == ISSUED_TOTAL
    assert platform_balance(factory, "PLATFORM_CLEARING") == -ISSUED_TOTAL

    # 可追溯：手续费恰好累计在官方 PLATFORM_FEE 科目。
    assert ledger.balance("PLATFORM_FEE") == fee
    # 红包无手续费：红包相关分录不触碰 PLATFORM_FEE。
    with factory() as session:
        fee_reasons = session.scalars(
            select(LedgerTransaction.reason_code).where(
                LedgerTransaction.scope.in_(["redpacket.create", "redpacket.claim"])
            )
        ).all()
    assert fee_reasons
    # 托管已清零：红包托管与转账托管科目余额为 0。
    assert ledger.balance(f"PLATFORM_RED_PACKET:{packet.id}") == Decimal("0.00")
    assert ledger.balance(f"PLATFORM_TRANSFER_ESCROW:{transfer.id}") == Decimal("0.00")

    posts = assert_every_transaction_balanced(factory)
    assert_traceability(factory, posts)


def test_expired_transfer_refund_also_preserves_supply(context):
    factory, ledger, settings, now = context
    transfers = ChatTransferService(factory, ledger)
    transfer = transfers.create(
        sender_id="alice",
        receiver_id="bravo",
        amount=Decimal("20.00"),
        idempotency_key="tx-exp",
        expires_at=now - timedelta(seconds=1),
    )
    transfers.expire(transfer.id, now=now, actor_id="worker", idempotency_key="exp-1")
    assert circulating_total(factory) == ISSUED_TOTAL
    assert platform_balance(factory, "PLATFORM_CLEARING") == -ISSUED_TOTAL
    # 过期退回：本金回 sender，手续费也从 PLATFORM_FEE 退回 sender。
    assert ledger.balance(f"PLATFORM_TRANSFER_ESCROW:{transfer.id}") == Decimal("0.00")
    assert ledger.balance("PLATFORM_FEE") == Decimal("0.00")
    assert_every_transaction_balanced(factory)
