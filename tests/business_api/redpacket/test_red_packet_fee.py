"""ADR-0073：红包手续费 0.5%（最低 0.01 点钻），与转账同构。

红包创建时向发送方收取 `max(0.01, total * 0.005)`，手续费进入官方
`PLATFORM_FEE` 科目；红包过期/取消且存在未领取份额时，未领取本金与
手续费一并退回发送方（与转账到期退款一致）。领取、分配公式与状态机不变。
"""
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.pool import StaticPool

from app.core.database import Base, create_session_factory
from app.modules.ledger.service import LedgerService
from app.modules.redpacket.membership import StaticRoomMembershipAuthority
from app.modules.redpacket.models import RedPacket
from app.modules.redpacket.service import RedPacketService, red_packet_fee
from app.modules.transfer.service import transfer_fee


@pytest.fixture()
def services():
    engine = create_engine(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    ledger = LedgerService(factory)
    ledger.adjust(
        user_id="sender",
        amount=Decimal("1000.00"),
        actor_id="finance",
        reason_code="INITIAL_CREDIT",
        idempotency_key="seed-fee",
    )
    membership = StaticRoomMembershipAuthority()
    membership.set_members("!room:test", {"sender", "alice", "bob"})
    service = RedPacketService(factory, ledger, room_membership=membership)
    yield service, ledger, factory
    engine.dispose()


def _expires():
    return datetime.now(timezone.utc) + timedelta(hours=24)


def test_fee_rule_matches_transfer_with_cent_floor():
    assert red_packet_fee(Decimal("10.00")) == Decimal("0.05")
    assert red_packet_fee(Decimal("200.00")) == Decimal("1.00")
    assert red_packet_fee(Decimal("5.00")) == Decimal("0.03")
    # 极小金额必须落到最低 0.01 点钻，而不是 0.00。
    assert red_packet_fee(Decimal("1.00")) == Decimal("0.01")
    assert red_packet_fee(Decimal("0.10")) == Decimal("0.01")
    # 与转账同费率、同取整、同下限。
    for amount in ("0.10", "1.00", "5.00", "10.00", "199.99"):
        assert red_packet_fee(Decimal(amount)) == transfer_fee(Decimal(amount))


def test_create_debits_total_plus_fee_and_records_platform_fee(services):
    service, ledger, factory = services
    packet = service.create_equal(
        sender_id="sender",
        total=Decimal("10.00"),
        share_count=2,
        room_id="!room:test",
        idempotency_key="rp-fee-create",
        expires_at=_expires(),
    )
    assert packet.fee == Decimal("0.05")
    assert ledger.balance("sender") == Decimal("989.95")
    assert ledger.balance(f"PLATFORM_REDPACKET_ESCROW:{packet.id}") == Decimal("10.00")
    assert ledger.balance("PLATFORM_FEE") == Decimal("0.05")
    # 持久化：手续费随红包单据落库（退款与对账都不必重算费率）。
    with factory() as session:
        stored = session.scalar(select(RedPacket).where(RedPacket.id == packet.id))
        assert stored is not None and stored.fee == Decimal("0.05")


def test_completed_packet_keeps_platform_fee(services):
    service, ledger, _ = services
    packet = service.create_equal(
        sender_id="sender",
        total=Decimal("1.00"),
        share_count=1,
        room_id="!room:test",
        idempotency_key="rp-fee-complete",
        expires_at=_expires(),
    )
    service.claim(packet.id, user_id="alice", idempotency_key="claim-fee-complete")
    assert ledger.balance("alice") == Decimal("1.00")
    # 全部领完：平台保留手续费（与已完成的转账一致），不做退款。
    assert ledger.balance("PLATFORM_FEE") == Decimal("0.01")
    assert ledger.balance("sender") == Decimal("998.99")


def test_expire_refunds_unclaimed_principal_and_full_fee(services):
    service, ledger, _ = services
    packet = service.create_equal(
        sender_id="sender",
        total=Decimal("10.00"),
        share_count=2,
        room_id="!room:test",
        idempotency_key="rp-fee-expire",
        expires_at=_expires(),
    )
    service.claim(packet.id, user_id="alice", idempotency_key="claim-fee-expire")
    service.expire(
        packet.id,
        now=datetime.now(timezone.utc) + timedelta(hours=25),
        actor_id="worker",
        idempotency_key="expire-fee",
    )
    # 未领 5.00 + 手续费 0.05 一并退回发送方：净支出只有被领走的 5.00。
    assert ledger.balance("sender") == Decimal("995.00")
    assert ledger.balance("alice") == Decimal("5.00")
    assert ledger.balance("PLATFORM_FEE") == Decimal("0.00")
    assert ledger.balance(f"PLATFORM_REDPACKET_ESCROW:{packet.id}") == Decimal("0.00")


def test_cancel_refunds_fee_with_unclaimed_shares(services):
    service, ledger, _ = services
    packet = service.create_equal(
        sender_id="sender",
        total=Decimal("2.00"),
        share_count=2,
        room_id="!room:test",
        idempotency_key="rp-fee-cancel",
        expires_at=_expires(),
    )
    service.claim(packet.id, user_id="alice", idempotency_key="claim-fee-cancel")
    service.cancel_unclaimed(
        packet.id,
        actor_id="supervisor",
        reason_code="ABNORMAL_RED_PACKET",
        idempotency_key="cancel-fee",
    )
    # 净支出只有被领走的 1.00；未领本金与手续费都退回。
    assert ledger.balance("sender") == Decimal("999.00")
    assert ledger.balance("alice") == Decimal("1.00")
    assert ledger.balance("PLATFORM_FEE") == Decimal("0.00")


def test_replayed_creation_charges_the_fee_once(services):
    service, ledger, _ = services
    first = service.create_equal(
        sender_id="sender",
        total=Decimal("10.00"),
        share_count=2,
        room_id="!room:test",
        idempotency_key="rp-fee-replay",
        expires_at=_expires(),
    )
    replay = service.create_equal(
        sender_id="sender",
        total=Decimal("10.00"),
        share_count=2,
        room_id="!room:test",
        idempotency_key="rp-fee-replay",
        expires_at=_expires(),
    )
    assert replay.id == first.id
    assert ledger.balance("sender") == Decimal("989.95")
    assert ledger.balance("PLATFORM_FEE") == Decimal("0.05")


def test_expire_without_claims_refunds_full_amount_and_fee(services):
    service, ledger, _ = services
    packet = service.create_random(
        sender_id="sender",
        total=Decimal("8.88"),
        share_count=4,
        recipient_id="alice",
        idempotency_key="rp-fee-none-claimed",
        expires_at=_expires(),
    )
    assert packet.fee == Decimal("0.04")
    service.expire(
        packet.id,
        now=datetime.now(timezone.utc) + timedelta(hours=25),
        actor_id="worker",
        idempotency_key="expire-fee-none",
    )
    assert ledger.balance("sender") == Decimal("1000.00")
    assert ledger.balance("PLATFORM_FEE") == Decimal("0.00")


def test_create_fee_transaction_carries_audit_and_outbox(services):
    """手续费走既有记账管道：每笔创建都有审计与事务性 Outbox（ADR-0073）。"""
    from app.core.outbox import OutboxEvent
    from app.modules.audit.models import AuditEvent
    from app.modules.ledger.models import LedgerTransaction

    service, _ledger, factory = services
    packet = service.create_equal(
        sender_id="sender",
        total=Decimal("10.00"),
        share_count=2,
        room_id="!room:test",
        idempotency_key="rp-fee-trace",
        expires_at=_expires(),
    )
    with factory() as session:
        transaction = session.scalar(
            select(LedgerTransaction).where(
                LedgerTransaction.scope == "redpacket.create"
            )
        )
        assert transaction is not None
        assert transaction.reason_code == "RED_PACKET_CREATE"
        assert transaction.actor_id == "sender"
        audits = session.scalars(
            select(AuditEvent).where(
                AuditEvent.subject_id == transaction.id,
                AuditEvent.action == "ledger.post",
            )
        ).all()
        outbox = session.scalars(
            select(OutboxEvent).where(
                OutboxEvent.aggregate_id == transaction.id,
                OutboxEvent.event_type == "ledger.posted",
            )
        ).all()
    assert len(audits) == 1 and audits[0].actor_id == "sender"
    assert len(outbox) == 1
    assert packet.fee == Decimal("0.05")
