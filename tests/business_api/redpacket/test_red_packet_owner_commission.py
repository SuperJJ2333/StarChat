"""ADR-0078：红包群主抽成 0.1% 与满 10 人群主免手续费。

金额示例（用户确认）：普通成员 100 点钻红包 → 本金 100、手续费 0.50、
实扣 100.50；手续费最终保留时群主得 0.10、平台剩 0.40。满 10 人群主
本人发 100 → 实扣 100、手续费 0、无抽成。过期退款的红包不发抽成。
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.pool import StaticPool

from app.core.database import Base, create_session_factory
from app.modules.ledger.models import LedgerEntry, LedgerTransaction
from app.modules.ledger.service import LedgerService
from app.modules.redpacket.membership import StaticRoomMembershipAuthority
from app.modules.redpacket.models import RedPacket
from app.modules.redpacket.service import RedPacketService, owner_commission, red_packet_fee
from app.modules.groups.registry import GroupRegistryService, matrix_owner_from_state


@pytest.fixture()
def env():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    ledger = LedgerService(factory)
    for user in ("sender", "owner", "alice", "bob", "carol", "dave", "erin", "frank", "grace", "heidi", "ivan", "judy"):
        ledger.adjust(user_id=user, amount=Decimal("1000.00"), actor_id="finance",
            reason_code="INITIAL_CREDIT", idempotency_key=f"seed-{user}")
    membership = StaticRoomMembershipAuthority()
    service = RedPacketService(factory, ledger, room_membership=membership)
    yield service, ledger, factory, membership
    engine.dispose()


def _registry(factory, owner="owner"):
    """测试用注册表替身：固定群主（业务 user id），满足 RedPacketService 注入面。"""

    class StaticRegistry:
        def __init__(self, user_id):
            self.user_id = user_id

        def owner_of(self, room_id):
            return self.user_id

    return StaticRegistry(owner)


def _expires():
    return datetime.now(timezone.utc) + timedelta(hours=24)


def _entries(factory, scope_prefix):
    with factory() as session:
        rows = session.scalars(select(LedgerEntry).join(LedgerTransaction, LedgerEntry.transaction_id == LedgerTransaction.id)
            .where(LedgerTransaction.scope == scope_prefix)).all()
        return {(r.account_id): (r.amount) for r in rows}


def _packet(factory, packet_id):
    with factory() as session:
        return session.get(RedPacket, packet_id)


def _balance(factory, account):
    with factory() as session:
        from sqlalchemy import func

        return Decimal(session.scalar(select(func.coalesce(func.sum(LedgerEntry.amount), 0))
            .where(LedgerEntry.account_id == account)))


# ---------------------------------------------------------------- 纯函数

def test_commission_formula_and_caps():
    assert owner_commission(Decimal("100.00"), Decimal("0.50")) == Decimal("0.10")
    # 小额舍入为 0 不强制 0.01
    assert owner_commission(Decimal("1.00"), Decimal("0.01")) == Decimal("0.00")
    assert owner_commission(Decimal("2.00"), Decimal("0.01")) == Decimal("0.00")
    # 抽成不得超过最终保留手续费
    assert owner_commission(Decimal("100.00"), Decimal("0.05")) == Decimal("0.05")
    # 大额 0.1% 精确
    assert owner_commission(Decimal("199.99"), Decimal("1.00")) == Decimal("0.20")


def test_commission_switch_only_affects_new_packets(env):
    service, _, factory, membership = env
    membership.set_members('!room:test', {'sender', 'owner', 'alice'})
    service.group_registry = _registry(factory)
    old = service.create_equal(total=Decimal('100'), share_count=1, sender_id='sender',
        idempotency_key='before-switch', expires_at=_expires(), room_id='!room:test')
    assert old.commission_status == 'PENDING'
    service.owner_commission_enabled = False
    new = service.create_equal(total=Decimal('100'), share_count=1, sender_id='sender',
        idempotency_key='after-switch', expires_at=_expires(), room_id='!room:test')
    assert new.commission_status == 'NONE' and new.fee == Decimal('0.50')
    service.claim(old.id, user_id='alice', idempotency_key='old-claim')
    assert _packet(factory, old.id).commission_status == 'SETTLED'


def test_create_replay_after_leaving_keeps_original_snapshot(env):
    service, _, factory, membership = env
    membership.set_members('!room:test', {'sender', 'owner', 'alice'})
    service.group_registry = _registry(factory)
    args = dict(total=Decimal('100'), share_count=1, sender_id='sender',
        idempotency_key='create-replay', expires_at=_expires(), room_id='!room:test')
    first = service.create_equal(**args)
    membership.set_members('!room:test', {'owner', 'alice'})
    service.group_registry.user_id = 'alice'
    replay = service.create_equal(**args)
    assert replay.id == first.id and replay.commission_beneficiary_id == 'owner'


# ---------------------------------------------------------------- 结算

def test_group_packet_settles_commission_once_when_completed(env):
    service, ledger, factory, membership = env
    membership.set_members("!room:test", {"sender", "alice", "bob", "owner"})
    service.group_registry = _registry(factory)
    packet = service.create_equal(total=Decimal("100.00"), share_count=2, sender_id="sender",
        idempotency_key="rp-comm-1", expires_at=_expires(), room_id="!room:test")
    assert packet.fee == Decimal("0.50")
    assert packet.commission_status == "PENDING"
    assert packet.commission_beneficiary_id == "owner"
    assert packet.rules_version == "rp-fee-v2"
    assert _balance(factory, "sender") == Decimal("1000.00") - Decimal("100.50")
    assert _balance(factory, "owner") == Decimal("1000.00")  # 未结算不增加可花余额
    service.claim(packet.id, user_id="alice", idempotency_key="c1")
    service.claim(packet.id, user_id="bob", idempotency_key="c2")
    row = _packet(factory, packet.id)
    assert row.status == "COMPLETED"
    assert row.commission_status == "SETTLED"
    assert row.commission_amount == Decimal("0.10")
    assert _balance(factory, "owner") == Decimal("1000.10")  # 直接进群主个人钱包
    assert _balance(factory, "PLATFORM_FEE") == Decimal("0.40")  # 平台净收入=0.50-0.10
    # 幂等：重复结算调用不产生新分录
    with factory.begin() as session:
        locked = session.get(RedPacket, packet.id, with_for_update=True)
        service._settle_commission(session, locked)
    assert _balance(factory, "owner") == Decimal("1000.10")


def test_small_packet_rounding_zero_means_no_commission(env):
    service, ledger, factory, membership = env
    membership.set_members("!room:test", {"sender", "alice", "bob", "owner"})
    service.group_registry = _registry(factory)
    packet = service.create_equal(total=Decimal("1.00"), share_count=1, sender_id="sender",
        idempotency_key="rp-comm-small", expires_at=_expires(), room_id="!room:test")
    assert packet.fee == Decimal("0.01")  # 最低手续费
    assert packet.commission_status == "NONE"  # 抽成舍入 0，不强制 0.01
    service.claim(packet.id, user_id="alice", idempotency_key="c1")
    assert _packet(factory, packet.id).commission_status == "NONE"
    assert _balance(factory, "owner") == Decimal("1000.00")


def test_private_packet_has_no_commission(env):
    service, ledger, factory, membership = env
    service.group_registry = _registry(factory)
    packet = service.create_equal(total=Decimal("100.00"), share_count=1, sender_id="sender",
        idempotency_key="rp-priv", expires_at=_expires(), recipient_id="alice")
    assert packet.commission_status == "NONE"
    assert packet.commission_beneficiary_id is None
    service.claim(packet.id, user_id="alice", idempotency_key="c1")
    assert _packet(factory, packet.id).commission_status == "NONE"


def test_expired_packet_forfeits_commission_and_refunds_fee(env):
    service, ledger, factory, membership = env
    membership.set_members("!room:test", {"sender", "alice", "bob", "owner"})
    service.group_registry = _registry(factory)
    packet = service.create_equal(total=Decimal("100.00"), share_count=2, sender_id="sender",
        idempotency_key="rp-exp", expires_at=_expires(), room_id="!room:test")
    service.claim(packet.id, user_id="alice", idempotency_key="c1")
    expired_at = datetime.now(timezone.utc) + timedelta(hours=25)
    service.expire(packet.id, now=expired_at, actor_id="worker", idempotency_key="exp-1")
    row = _packet(factory, packet.id)
    assert row.status == "EXPIRED"
    assert row.commission_status == "FORFEITED"  # 退还手续费的红包不发抽成
    assert _balance(factory, "owner") == Decimal("1000.00")
    # 1000 - 100.50(创建) + 50.00(未领本金) + 0.50(全费退回) = 950.00
    assert _balance(factory, "sender") == Decimal("950.00")
    # 平台保留 0.50 - 已退 0.50 = 0
    assert _balance(factory, "PLATFORM_FEE") == Decimal("0.00")


def test_worker_sweep_settles_pending_after_completion(env):
    service, ledger, factory, membership = env
    membership.set_members("!room:test", {"sender", "alice", "bob", "owner"})
    service.group_registry = _registry(factory)
    packet = service.create_equal(total=Decimal("100.00"), share_count=1, sender_id="sender",
        idempotency_key="rp-sweep", expires_at=_expires(), room_id="!room:test")
    service.claim(packet.id, user_id="alice", idempotency_key="c1")
    with factory.begin() as session:
        row = session.get(RedPacket, packet.id)
        row.commission_status = "PENDING"  # 模拟历史遗漏
        row.commission_amount = None
    settled = service.settle_pending_commissions()
    assert settled == 1
    row = _packet(factory, packet.id)
    assert row.commission_status == "SETTLED" and row.commission_amount == Decimal("0.10")
    assert service.settle_pending_commissions() == 0  # 幂等


def test_owner_transfer_after_creation_does_not_change_beneficiary(env):
    service, ledger, factory, membership = env
    membership.set_members("!room:test", {"sender", "alice", "bob", "owner"})
    registry = _registry(factory)
    service.group_registry = registry
    packet = service.create_equal(total=Decimal("100.00"), share_count=1, sender_id="sender",
        idempotency_key="rp-own-1", expires_at=_expires(), room_id="!room:test")
    assert packet.commission_beneficiary_id == "owner"
    registry.user_id = "newowner"  # 群主转让（快照后）
    service.claim(packet.id, user_id="alice", idempotency_key="c1")
    row = _packet(factory, packet.id)
    assert row.commission_beneficiary_id == "owner"  # 受益人不随转让改变
    assert _balance(factory, "owner") == Decimal("1000.10")
    assert _balance(factory, "newowner") == Decimal("0.00")  # 转让后新群主不追溯受益


def test_owner_exemption_requires_ten_members_and_owner_sender(env):
    """满 10 人群主本群免手续费零抽成；9 人群主仍付费有抽成；满 10 人
    非群主仍付费有抽成。"""
    service, ledger, factory, membership = env
    ten = {"owner", "sender", "alice", "bob", "carol", "dave", "erin", "frank", "grace", "heidi"}
    membership.set_members("!room:big", ten)
    service.group_registry = _registry(factory, owner="owner")
    packet = service.create_equal(total=Decimal("100.00"), share_count=1, sender_id="owner",
        idempotency_key="rp-big-owner", expires_at=_expires(), room_id="!room:big")
    assert packet.fee == Decimal("0.00")
    assert packet.fee_exempt is True and packet.fee_exempt_reason == "GROUP_OWNER_TEN_PLUS"
    assert packet.commission_status == "NONE"
    assert _balance(factory, "owner") == Decimal("1000.00") - Decimal("100.00")  # 实扣=本金

    nine = {"owner", "sender", "alice", "bob", "carol", "dave", "erin", "frank", "grace"}
    membership.set_members("!room:nine", nine)
    small = service.create_equal(total=Decimal("100.00"), share_count=1, sender_id="owner",
        idempotency_key="rp-nine-owner", expires_at=_expires(), room_id="!room:nine")
    assert small.fee == Decimal("0.50")  # 9 人群主不豁免
    assert small.commission_status == "PENDING"

    big_non_owner = service.create_equal(total=Decimal("100.00"), share_count=1, sender_id="sender",
        idempotency_key="rp-big-non-owner", expires_at=_expires(), room_id="!room:big")
    assert big_non_owner.fee == Decimal("0.50")  # 满 10 人非群主不豁免
    assert big_non_owner.commission_status == "PENDING"
    assert big_non_owner.commission_beneficiary_id == "owner"


def test_registry_unwired_never_exempts_and_never_commissions(env):
    """注册表未接线（测试/worker 构造）：不豁免（费用照收）、无抽成快照；
    生产装配必须接线（ADR-0078）。"""
    service, ledger, factory, membership = env
    ten = {"sender", "alice", "bob", "carol", "dave", "erin", "frank", "grace", "heidi", "ivan"}
    membership.set_members("!room:big", ten)
    packet = service.create_equal(total=Decimal("100.00"), share_count=1, sender_id="sender",
        idempotency_key="rp-unwired", expires_at=_expires(), room_id="!room:big")
    assert packet.fee == Decimal("0.50")
    assert packet.commission_status == "NONE"


# ---------------------------------------------------------------- 注册表

class FakeGateway:
    def __init__(self, power_users=None, members=None):
        self.power_users = power_users or {}
        self.members = members or set()

    def get_room_state(self, room_id):
        return [{"type": "m.room.power_levels", "content": {"users": self.power_users}}]

    def get_room_members(self, room_id):
        return self.members


def _user(factory, user_id, matrix_id):
    from app.modules.identity.enums import AccountStatus
    from app.modules.identity.models import User

    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(User(id=user_id, username=user_id, username_normalized=user_id,
            email=f"{user_id}@example.com", email_normalized=f"{user_id}@example.com",
            password_hash="x", status=AccountStatus.ACTIVE, matrix_user_id=matrix_id,
            email_verified_at=now, created_at=now, updated_at=now))


def test_matrix_owner_from_state_requires_unique_creator_power():
    assert matrix_owner_from_state([{"type": "m.room.power_levels", "content": {"users": {"@a:x": 100, "@b:x": 50}}}]) == "@a:x"
    assert matrix_owner_from_state([{"type": "m.room.power_levels", "content": {"users": {"@a:x": 50}}}]) is None
    assert matrix_owner_from_state([{"type": "m.room.power_levels", "content": {"users": {"@a:x": 100, "@b:x": 100}}}]) is None


def test_registry_register_creation_and_tenure(tmp_path=None):
    from app.core.database import Base, create_session_factory
    from sqlalchemy import create_engine
    from sqlalchemy.pool import StaticPool

    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    _user(factory, "creator", "@creator:x")
    _user(factory, "member", "@member:x")
    gateway = FakeGateway(power_users={"@creator:x": 100}, members={"@creator:x"})
    registry = GroupRegistryService(factory, matrix_gateway=gateway)
    row = registry.register_creation("!room:new", "creator")
    assert row.owner_since is not None and row.tenure_source == "creation"
    # 非创建者不能注册
    try:
        registry.register_creation("!room:new2", "member")
        assert False, "member should not register creation"
    except Exception as exc:
        assert getattr(exc, "code", "") == "GROUP_CREATOR_POWER_REQUIRED"
    engine.dispose()
