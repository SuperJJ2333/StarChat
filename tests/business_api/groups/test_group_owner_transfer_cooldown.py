"""ADR-0079：业务群注册表与群主转让冷却。

- 冷却从当前群主接任时间起算；joined ≥10 时须任满 30×24h（服务端 UTC）。
- 达到 10 人不重置接任时间；不足 10 人不新增限制。
- 并发转让单赢家；失败/超时/重试不提前变更接任时间。
- Matrix 权限不是财务权威：改 Matrix 权限不能绕过冷却或改变受益人。
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.pool import StaticPool

from app.core.database import Base, create_session_factory
from app.modules.groups.models import BusinessGroup
from app.modules.groups.registry import (
    COOLDOWN_MIN_MEMBERS,
    COOLDOWN_PERIOD,
    GroupOwnerError,
    GroupRegistryService,
)


class FakeGateway:
    def __init__(self, power_users=None, members=None):
        self.power_users = power_users or {}
        self.members = members or set()

    def get_room_state(self, room_id):
        return [{"type": "m.room.power_levels", "content": {"users": self.power_users}}]

    def get_room_members(self, room_id):
        return self.members


@pytest.fixture()
def env(tmp_path):
    engine = create_engine(f"sqlite+pysqlite:///{tmp_path / 'groups.db'}",
        connect_args={"check_same_thread": False, "timeout": 15})
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime(2026, 9, 21, 0, 0, tzinfo=timezone.utc)
    _user(factory, "owner", "@owner:x", now)
    _user(factory, "newowner", "@newowner:x", now)
    gateway = FakeGateway(power_users={"@owner:x": 100, "@newowner:x": 50},
        members={"@owner:x", "@newowner:x", *{f"@u{i}:x" for i in range(10)}})
    registry = GroupRegistryService(factory, matrix_gateway=gateway, now=lambda: now)
    yield factory, registry, gateway, now
    engine.dispose()


def _user(factory, user_id, matrix_id, now):
    from app.modules.identity.enums import AccountStatus
    from app.modules.identity.models import User

    with factory.begin() as session:
        session.add(User(id=user_id, username=user_id, username_normalized=user_id,
            email=f"{user_id}@example.com", email_normalized=f"{user_id}@example.com",
            password_hash="x", status=AccountStatus.ACTIVE, matrix_user_id=matrix_id,
            email_verified_at=now, created_at=now, updated_at=now))


def _seed_group(factory, *, owner="owner", owner_since=None, source=None, now=None):
    with factory.begin() as session:
        session.add(BusinessGroup(room_id="!room:x", owner_user_id=owner, owner_since=owner_since,
            tenure_source=source, created_at=now or datetime.now(timezone.utc),
            updated_at=now or datetime.now(timezone.utc)))


def test_below_ten_members_transfer_allowed_without_proven_tenure(env):
    factory, registry, gateway, now = env
    gateway.members = {"@owner:x", "@newowner:x", "@a:x"}  # 3 人
    _seed_group(factory, owner_since=None, source=None, now=now)  # 旧群任期不可证明
    row = registry.transfer("!room:x", current_owner_user_id="owner", new_owner_user_id="newowner")
    assert row.owner_user_id == "newowner"
    assert row.owner_since is not None and row.tenure_source == "transfer"


def test_ten_members_with_unproven_tenure_rejected(env):
    factory, registry, gateway, now = env
    _seed_group(factory, owner_since=None, source=None, now=now)
    with pytest.raises(GroupOwnerError) as excinfo:
        registry.transfer("!room:x", current_owner_user_id="owner", new_owner_user_id="newowner")
    assert excinfo.value.code == "OWNER_TENURE_UNPROVEN"
    # 失败不得变更接任时间/所有权
    row = factory() and None
    with factory() as session:
        row = session.get(BusinessGroup, "!room:x")
    assert row.owner_user_id == "owner" and row.owner_since is None


def test_ten_members_just_under_30_days_rejected(env):
    factory, registry, gateway, now = env
    _seed_group(factory, owner_since=now - COOLDOWN_PERIOD + timedelta(seconds=1), source="creation", now=now)
    with pytest.raises(GroupOwnerError) as excinfo:
        registry.transfer("!room:x", current_owner_user_id="owner", new_owner_user_id="newowner")
    assert excinfo.value.code == "OWNER_TENURE_INSUFFICIENT"


def test_exactly_thirty_days_allows_transfer(env):
    factory, registry, gateway, now = env
    _seed_group(factory, owner_since=now - COOLDOWN_PERIOD, source="creation", now=now)
    row = registry.transfer("!room:x", current_owner_user_id="owner", new_owner_user_id="newowner")
    assert row.owner_user_id == "newowner"
    # 新群主接任时间 = 本次转让成功时间
    assert row.owner_since == now


def test_reaching_ten_members_does_not_reset_tenure(env):
    """接任时间只在注册/转让时写入；成员增长不改写 owner_since。"""
    factory, registry, gateway, now = env
    started = now - timedelta(days=45)
    _seed_group(factory, owner_since=started, source="creation", now=now)
    gateway.members = {"@owner:x", "@newowner:x", *{f"@u{i}:x" for i in range(13)}}  # 人数增长到 15
    row = registry.transfer("!room:x", current_owner_user_id="owner", new_owner_user_id="newowner")
    assert row.owner_user_id == "newowner"  # 45 天前接任 → 满 10 人也可转让
    assert row.owner_since == now


def test_non_owner_cannot_transfer(env):
    factory, registry, gateway, now = env
    _seed_group(factory, owner_since=now - COOLDOWN_PERIOD, source="creation", now=now)
    with pytest.raises(GroupOwnerError) as excinfo:
        registry.transfer("!room:x", current_owner_user_id="newowner", new_owner_user_id="owner")
    assert excinfo.value.code == "GROUP_OWNER_MISMATCH"


def test_concurrent_transfer_single_winner(env):
    factory, registry, gateway, now = env
    _seed_group(factory, owner_since=now - COOLDOWN_PERIOD, source="creation", now=now)

    import time

    def attempt(new_owner):
        time.sleep(0.05)
        try:
            r = registry.transfer("!room:x", current_owner_user_id="owner", new_owner_user_id=new_owner)
            return r.owner_user_id
        except GroupOwnerError as exc:
            return exc.code

    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(attempt, ["newowner", "newowner", "newowner", "newowner"]))
    winners = [r for r in results if r == "newowner"]
    assert len(winners) == 1
    assert results.count("GROUP_OWNER_MISMATCH") + results.count("GROUP_TRANSFER_CONCURRENT") >= 1
    with factory() as session:
        row = session.get(BusinessGroup, "!room:x")
    assert row.owner_user_id == "newowner"


def test_admin_tenure_migration_requires_reason_and_writes_audit(env):
    factory, registry, gateway, now = env
    _seed_group(factory, owner_since=None, source=None, now=now)
    with pytest.raises(GroupOwnerError) as excinfo:
        registry.admin_set_tenure("!room:x", owner_since=now - timedelta(days=60), reason_code="  ", actor_id="admin")
    assert excinfo.value.code == "GROUP_TENURE_REASON_REQUIRED"
    row = registry.admin_set_tenure("!room:x", owner_since=now - timedelta(days=60), reason_code="LEGACY_MIGRATION_001", actor_id="admin")
    assert row.owner_since == now - timedelta(days=60) and row.tenure_source == "admin_migration"
    from app.modules.audit.models import AuditEvent

    with factory() as session:
        event = session.scalar(select(AuditEvent).where(AuditEvent.action == "group.owner_tenure_migrated"))
    assert event is not None and event.reason_code == "LEGACY_MIGRATION_001"


def test_matrix_power_change_alone_cannot_reset_registry(env):
    """直接改 Matrix 权限不能变更注册表（绕过冷却/获取抽成权益被阻断）。"""
    factory, registry, gateway, now = env
    _seed_group(factory, owner_since=now - timedelta(days=1), source="creation", now=now)
    gateway.power_users = {"@newowner:x": 100, "@owner:x": 50}  # Matrix 侧被改成新群主
    view = registry.group_view("!room:x")
    assert view["owner_user_id"] == "owner"  # 注册表不变
    assert view["matrix_power_owner"] == "@newowner:x"
    assert view["owner_desync"] is True
    with pytest.raises(GroupOwnerError) as excinfo:
        registry.transfer("!room:x", current_owner_user_id="owner", new_owner_user_id="newowner")
    assert excinfo.value.code == "OWNER_TENURE_INSUFFICIENT"  # 冷却仍按接任时间计算


def test_matrix_authority_unavailable_fails_closed(env):
    factory, registry, gateway, now = env
    _seed_group(factory, owner_since=None, source=None, now=now)

    class DeadGateway:
        def get_room_members(self, room_id):
            raise RuntimeError("synapse down")

    dead = GroupRegistryService(factory, matrix_gateway=DeadGateway(), now=lambda: now)
    with pytest.raises(GroupOwnerError) as excinfo:
        dead.transfer("!room:x", current_owner_user_id="owner", new_owner_user_id="newowner")
    assert excinfo.value.code == "GROUP_AUTHORITY_UNAVAILABLE"


def test_cooldown_constants_match_user_decision():
    assert COOLDOWN_PERIOD == timedelta(days=30)
    assert COOLDOWN_MIN_MEMBERS == 10
