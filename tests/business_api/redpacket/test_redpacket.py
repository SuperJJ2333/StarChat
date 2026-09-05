from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.pool import StaticPool

from app.core.database import Base, create_session_factory
from app.modules.ledger.service import LedgerService
from app.modules.redpacket.claims import RedPacketClaim
from app.modules.redpacket.membership import StaticRoomMembershipAuthority
from app.modules.redpacket.service import RedPacketService

@pytest.fixture()
def membership():
    return StaticRoomMembershipAuthority()

@pytest.fixture()
def services(membership):
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    ledger = LedgerService(factory)
    ledger.adjust(user_id="sender", amount=Decimal("100.00"), actor_id="finance", reason_code="INITIAL_CREDIT", idempotency_key="seed-red")
    # F06：群红包查看/领取需要权威房间成员校验（测试注入静态成员表）。
    membership.set_members("!room:test", {"alice", "bob"})
    yield RedPacketService(factory, ledger, room_membership=membership), ledger, membership
    engine.dispose()

def test_equal_group_red_packet_claim_and_expire_refund(services):
    service, ledger, _ = services
    packet = service.create_equal(sender_id="sender", total=Decimal("10.00"), share_count=3, room_id="!room:test", idempotency_key="rp-equal", expires_at=datetime.now(timezone.utc) + timedelta(hours=24))
    assert [share.amount for share in packet.shares] == [Decimal("3.34"), Decimal("3.33"), Decimal("3.33")]
    claimed = service.claim(packet.id, user_id="alice", idempotency_key="claim-a")
    assert claimed.amount == Decimal("3.34")
    service.expire(packet.id, now=datetime.now(timezone.utc) + timedelta(hours=25), actor_id="worker", idempotency_key="expire-a")
    assert ledger.balance("alice") == Decimal("3.34")
    assert ledger.balance("sender") == Decimal("96.66")

def test_random_packet_sums_exactly_and_user_claims_once(services):
    service, _ledger, _ = services
    packet = service.create_random(sender_id="sender", total=Decimal("8.88"), share_count=8, recipient_id="friend", idempotency_key="rp-random", expires_at=datetime.now(timezone.utc) + timedelta(hours=24))
    assert sum((share.amount for share in packet.shares), Decimal("0.00")) == Decimal("8.88")
    assert all(share.amount >= Decimal("0.01") for share in packet.shares)
    service.claim(packet.id, user_id="friend", idempotency_key="claim-1")
    with pytest.raises(ValueError, match="already claimed"):
        service.claim(packet.id, user_id="friend", idempotency_key="claim-2")

def test_authorized_cancel_refunds_only_unclaimed(services):
    service, ledger, _ = services
    packet = service.create_equal(sender_id="sender", total=Decimal("2.00"), share_count=2, room_id="!room:test", idempotency_key="rp-cancel", expires_at=datetime.now(timezone.utc) + timedelta(hours=24))
    service.claim(packet.id, user_id="alice", idempotency_key="claim-cancel")
    service.cancel_unclaimed(packet.id, actor_id="supervisor", reason_code="ABNORMAL_RED_PACKET", idempotency_key="cancel-1")
    assert ledger.balance("sender") == Decimal("99.00")
    assert ledger.balance("alice") == Decimal("1.00")


# ── F06：群红包房间成员授权矩阵 ────────────────────────────────

def test_f06_room_member_can_claim_non_member_cannot(services):
    """成员可领；非成员不可领且不留任何领取记录/账本分录。"""
    service, ledger, _ = services
    packet = service.create_equal(sender_id="sender", total=Decimal("3.00"), share_count=3, room_id="!room:test", idempotency_key="rp-f06-a", expires_at=datetime.now(timezone.utc) + timedelta(hours=24))
    # 非成员被拒。
    with pytest.raises(ValueError, match="room membership required"):
        service.claim(packet.id, user_id="mallory", idempotency_key="claim-mallory")
    with pytest.raises(ValueError, match="room membership required"):
        service.detail(packet.id, user_id="mallory")
    # 授权失败不得新增领取记录或账本分录。
    engine_ledger_unchanged = ledger.balance("mallory") == Decimal("0.00")
    assert engine_ledger_unchanged
    # 成员正常领取。
    share = service.claim(packet.id, user_id="alice", idempotency_key="claim-alice")
    assert share.amount == Decimal("1.00")
    assert ledger.balance("alice") == Decimal("1.00")

def test_f06_left_member_cannot_claim_or_view(services):
    """退群/被踢（不再属于当前 join 成员集合）→ 不可见、不可领。"""
    service, ledger, membership = services
    packet = service.create_equal(sender_id="sender", total=Decimal("2.00"), share_count=2, room_id="!room:test", idempotency_key="rp-f06-b", expires_at=datetime.now(timezone.utc) + timedelta(hours=24))
    # bob 在群里时可领。
    assert service.claim(packet.id, user_id="bob", idempotency_key="claim-bob").amount == Decimal("1.00")
    # alice 退群（成员集合移除）→ 不可见、不可领。
    membership.set_members("!room:test", {"bob"})
    with pytest.raises(ValueError, match="room membership required"):
        service.claim(packet.id, user_id="alice", idempotency_key="claim-alice")
    with pytest.raises(ValueError, match="room membership required"):
        service.detail(packet.id, user_id="alice")
    assert ledger.balance("alice") == Decimal("0.00")

def test_f06_sender_and_exclusive_recipient_still_allowed(services):
    """发起人本人可见/可领自己的群红包；专属红包仍按接收人判定。"""
    service, _, _ = services
    packet = service.create_equal(sender_id="sender", total=Decimal("1.00"), share_count=1, room_id="!room:test", idempotency_key="rp-f06-c", expires_at=datetime.now(timezone.utc) + timedelta(hours=24))
    assert service.claim(packet.id, user_id="sender", idempotency_key="claim-sender").amount == Decimal("1.00")
    exclusive = service.create_exclusive(sender_id="sender", total=Decimal("1.00"), share_count=1, room_id="!room:test", recipient_id="friend", idempotency_key="rp-f06-d", expires_at=datetime.now(timezone.utc) + timedelta(hours=24))
    # 非接收人对专属红包的领取先被 recipient 判定拒绝（仍在 OPEN 时）。
    with pytest.raises(ValueError, match="recipient mismatch"):
        service.claim(exclusive.id, user_id="alice", idempotency_key="claim-wrong")
    assert service.claim(exclusive.id, user_id="friend", idempotency_key="claim-friend").amount == Decimal("1.00")

def test_f06_fail_closed_without_authority():
    """未配置成员权威（None）时群红包仅发起人本人——fail closed。"""
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    ledger = LedgerService(factory)
    ledger.adjust(user_id="sender", amount=Decimal("5.00"), actor_id="finance", reason_code="INITIAL_CREDIT", idempotency_key="seed-f06")
    service = RedPacketService(factory, ledger, room_membership=None)
    packet = service.create_equal(sender_id="sender", total=Decimal("1.00"), share_count=1, room_id="!room:test", idempotency_key="rp-f06-e", expires_at=datetime.now(timezone.utc) + timedelta(hours=24))
    with pytest.raises(ValueError, match="room membership required"):
        service.claim(packet.id, user_id="anyone", idempotency_key="claim-x")
    assert service.claim(packet.id, user_id="sender", idempotency_key="claim-s").amount == Decimal("1.00")
    engine.dispose()

def test_f06_unauthorized_claim_writes_nothing(services):
    """授权拒绝在写任何领取记录/账本分录之前完成（回归断言）。"""
    service, ledger, membership = services
    packet = service.create_equal(sender_id="sender", total=Decimal("1.00"), share_count=1, room_id="!room:test", idempotency_key="rp-f06-f", expires_at=datetime.now(timezone.utc) + timedelta(hours=24))
    with pytest.raises(ValueError, match="room membership required"):
        service.claim(packet.id, user_id="stranger", idempotency_key="claim-stranger")
    engine = service.session_factory
    with engine() as session:
        claims = session.scalars(select(RedPacketClaim).where(RedPacketClaim.user_id == "stranger")).all()
    assert claims == []
    assert ledger.balance("stranger") == Decimal("0.00")
