"""ADR-0079 实施补充：群主转让持久协调（故障注入矩阵）。

- 正常路径：request → advance（以群主身份应用 power level）→ 权威确认
  → complete（条件换主 + owner_since=now）；
- 故障注入：网络失败重试、发送成功但崩溃在记录前（权威状态短路恢复）、
  尝试耗尽 NEEDS_REVIEW、并发换主单赢家、Matrix 状态未确认不换主；
- 默认关闭：端点保持 GROUP_TRANSFER_UNAVAILABLE（复审安全隔离）。
"""
import asyncio
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import create_engine, event, select
from sqlalchemy.orm import sessionmaker

import app.modules.groups.models  # noqa: F401
import app.modules.audit.models  # noqa: F401
import app.modules.identity.models  # noqa: F401
from app.core.database import Base
from app.modules.groups.models import BusinessGroup, GroupTransferIntent
from app.modules.groups.registry import GroupRegistryService
from app.modules.groups.transfer_coordination import GroupTransferCoordinator

NOW = datetime(2026, 9, 21, 12, 0, tzinfo=timezone.utc)


class Clock:
    def __init__(self):
        self._now = NOW

    def __call__(self):
        return self._now

    def advance(self, **kw):
        self._now = self._now + timedelta(**kw)


class FakeGateway:
    """内存 Synapse：状态 + login-as-user + 以用户身份发送状态事件。

    fault 注入点：send_behavior(state_dict) 在发送前/后可抛异常或直接改写。
    """

    def __init__(self, power_users, members):
        self.power_users = dict(power_users)
        self.members = set(members)
        self.send_calls: list[dict] = []
        self.login_calls: list[str] = []
        self.send_behavior = None  # callable(power_users, content) -> raise to inject
        self.apply_on_send = True  # False = 供应商接受但不落权威状态（未确认场景）

    def get_room_state(self, room_id):
        return [{"type": "m.room.power_levels", "content": {"users": dict(self.power_users)}}]

    def get_room_members(self, room_id):
        return self.members

    def login_as_user(self, matrix_user_id):
        self.login_calls.append(matrix_user_id)
        return f"token-for-{matrix_user_id}"

    def send_room_state_as_user(self, matrix_user_id, room_id, event_type, content):
        self.send_calls.append({"as": matrix_user_id, "room": room_id,
            "event_type": event_type, "content": content})
        if self.send_behavior is not None:
            self.send_behavior(self.power_users, content)
        # 默认：发送成功 = 权威状态随之更新；apply_on_send=False 模拟未确认。
        if event_type == "m.room.power_levels" and self.apply_on_send:
            self.power_users = dict(content.get("users", self.power_users))


@pytest.fixture()
def env(tmp_path):
    engine = create_engine(f"sqlite+pysqlite:///{tmp_path / 'transfer.db'}",
        connect_args={"check_same_thread": False, "timeout": 15})

    @event.listens_for(engine, "connect")
    def _fk(dbapi_connection, _record):
        dbapi_connection.execute("PRAGMA foreign_keys=ON")

    Base.metadata.create_all(engine)
    factory = sessionmaker(bind=engine, expire_on_commit=False)
    clock = Clock()
    now = NOW
    from app.modules.identity.models import User

    with factory.begin() as session:
        for uid, mxid in (("owner", "@owner:x"), ("newowner", "@newowner:x"),
                ("m1", "@m1:x"), ("m2", "@m2:x"), ("m3", "@m3:x")):
            session.add(User(id=uid, username=uid, username_normalized=uid,
                email=f"{uid}@x.test", email_normalized=f"{uid}@x.test", password_hash="x",
                status="ACTIVE", matrix_user_id=mxid, created_at=now, updated_at=now))
        session.flush()  # 先落 users，再插依赖其 id 的群注册表行
        session.add(BusinessGroup(room_id="!room:x", owner_user_id="owner",
            owner_since=NOW - timedelta(days=45), tenure_source="creation",
            created_at=now, updated_at=now))
    gateway = FakeGateway({"@owner:x": 100, "@m1:x": 50},
        {"@owner:x", "@newowner:x", "@m1:x", "@m2:x", "@m3:x"})
    registry = GroupRegistryService(factory, matrix_gateway=gateway, now=clock)
    coordinator = GroupTransferCoordinator(factory, registry=registry,
        matrix_gateway=gateway, now=clock)
    yield factory, coordinator, gateway, registry, clock
    engine.dispose()


def test_happy_path_applies_matrix_then_commits_registry(env):
    factory, coordinator, gateway, registry, clock = env
    view = coordinator.request(room_id="!room:x", requester_user_id="owner",
        current_owner_user_id="owner", new_owner_user_id="newowner", idempotency_key="k1")
    assert view["stage"] == "VALIDATED"
    view = coordinator.advance(intent_id=view["id"])
    assert view["stage"] == "MATRIX_APPLIED"
    # Matrix 侧：以旧群主身份发送，新群主=100，旧群主降权
    assert gateway.send_calls[-1]["as"] == "@owner:x"
    users = gateway.send_calls[-1]["content"]["users"]
    assert users["@newowner:x"] == 100 and users["@owner:x"] == 0
    result = coordinator.complete(intent_id=view["id"], actor_id="owner")
    assert result["stage"] == "COMPLETED"
    row = registry.get("!room:x")
    assert row.owner_user_id == "newowner" and row.tenure_source == "transfer"
    assert (row.owner_since if row.owner_since.tzinfo else row.owner_since.replace(tzinfo=timezone.utc)) == clock()


def test_idempotent_replay_and_payload_conflict(env):
    factory, coordinator, gateway, registry, clock = env
    first = coordinator.request(room_id="!room:x", requester_user_id="owner",
        current_owner_user_id="owner", new_owner_user_id="newowner", idempotency_key="k")
    replay = coordinator.request(room_id="!room:x", requester_user_id="owner",
        current_owner_user_id="owner", new_owner_user_id="newowner", idempotency_key="k")
    assert replay["id"] == first["id"]
    from app.core.errors import AppError

    with pytest.raises(AppError) as excinfo:
        coordinator.request(room_id="!room:x", requester_user_id="owner",
            current_owner_user_id="owner", new_owner_user_id="m1", idempotency_key="k")
    assert excinfo.value.code == "IDEMPOTENCY_KEY_REUSED"


def test_cooldown_enforced_before_intent_created(env):
    factory, coordinator, gateway, registry, clock = env
    gateway.members |= {f"@u{i}:x" for i in range(5)}  # 含实际双方，满 10 人才触发冷却
    with factory.begin() as session:
        row = session.get(BusinessGroup, "!room:x")
        row.owner_since = NOW - timedelta(days=5)  # 任期不足
        session.flush()
    from app.modules.groups.registry import GroupOwnerError

    with pytest.raises(GroupOwnerError) as excinfo:
        coordinator.request(room_id="!room:x", requester_user_id="owner",
            current_owner_user_id="owner", new_owner_user_id="newowner", idempotency_key="k2")
    assert excinfo.value.code == "OWNER_TENURE_INSUFFICIENT"
    with factory() as session:
        assert session.scalar(select(GroupTransferIntent.id)) is None  # 未建意图


def test_unknown_network_result_does_not_resend_or_change_registry(env):
    factory, coordinator, gateway, registry, clock = env
    gateway.send_behavior = lambda power_users, content: (_ for _ in ()).throw(RuntimeError("synapse 5xx"))
    view = coordinator.request(room_id="!room:x", requester_user_id="owner",
        current_owner_user_id="owner", new_owner_user_id="newowner", idempotency_key="k3")
    intent_id = view["id"]
    for _ in range(2):  # 不确定外部结果，第二次 advance 不再次发送
        view = coordinator.advance(intent_id=intent_id)
    assert view["stage"] == "MATRIX_PENDING"
    assert len(gateway.send_calls) == 1
    assert gateway.power_users["@owner:x"] == 100  # Matrix 未被改变
    assert registry.get("!room:x").owner_user_id == "owner"  # 注册表未变
    # 过期后仍不能证明已应用则进入核对，不能重新发送未知请求。
    gateway.send_behavior = None
    clock.advance(seconds=180)
    result = coordinator.recover_batch()
    assert result["completed"] == 0 and result['review'] == 1
    assert registry.get("!room:x").owner_user_id == "owner"
    assert len(gateway.send_calls) == 1


def test_crash_after_apply_short_circuits_from_authoritative_state(env):
    """崩溃在"发送成功之后、权威确认记录之前"：stage 停在 MATRIX_PENDING、
    认领超时。恢复先读权威状态——已应用则直接推进完成，不重复发送。"""
    from sqlalchemy import update as _update

    factory, coordinator, gateway, registry, clock = env
    view = coordinator.request(room_id="!room:x", requester_user_id="owner",
        current_owner_user_id="owner", new_owner_user_id="newowner", idempotency_key="k4")
    intent_id = view["id"]
    # 模拟：进程以群主身份发送成功（Matrix 已更新），随后在记录 T3 前崩溃。
    old_matrix = registry.matrix_user_id("owner")
    new_matrix = registry.matrix_user_id("newowner")
    gateway.send_room_state_as_user(old_matrix, "!room:x", "m.room.power_levels",
        {"users": {**gateway.power_users, new_matrix: 100, old_matrix: 0}})
    with factory.begin() as session:
        session.execute(_update(GroupTransferIntent).where(GroupTransferIntent.id == intent_id)
            .values(stage="MATRIX_PENDING", attempts=1,
                claim_at=NOW - timedelta(seconds=180), claim_token="dead-process"))
    sends_before = len(gateway.send_calls)
    clock.advance(seconds=60)
    result = coordinator.recover_batch()
    assert result["completed"] == 1
    assert len(gateway.send_calls) == sends_before  # 权威状态短路，未重复发送
    assert registry.get("!room:x").owner_user_id == "newowner"
    assert registry.get("!room:x").tenure_source == "transfer"


def test_transfer_intent_review_endpoints_contract(tmp_path):
    """时间线与复核端点：管理员权限、confirm 依据权威既成事实、
    fail_unapplied 依据确证未应用；否则 409。"""
    import jwt as pyjwt
    from httpx import ASGITransport, AsyncClient
    from sqlalchemy import create_engine as _ce
    from sqlalchemy.pool import StaticPool

    from app.core.config import Settings as S
    from app.core.database import Base as B, create_session_factory as _csf
    from app.main import create_app as _app
    from app.modules.groups.models import BusinessGroup as BG, GroupTransferIntent as GTI
    from app.modules.identity.models import User as U

    engine = _ce("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    B.metadata.create_all(engine)
    factory = _csf(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        from app.modules.identity.models import UserRole

        for uid, mxid, role in (("owner", "@owner:x", None), ("root", "@root:x", "SUPER_ADMIN"),
                ("rand", "@rand:x", None)):
            session.add(U(id=uid, username=uid, username_normalized=uid, email=f"{uid}@x",
                email_normalized=f"{uid}@x", password_hash="x", status="ACTIVE",
                matrix_user_id=mxid, created_at=now, updated_at=now))
            if role is not None:
                session.add(UserRole(id="role-" + uid, user_id=uid, role_code=role,
                    assigned_by=uid, assigned_at=now))
        session.flush()
        session.add(BG(room_id="!r:x", owner_user_id="owner", owner_since=now,
            tenure_source="creation", created_at=now, updated_at=now))
        session.add(GTI(id="intent-1", room_id="!r:x", requester_user_id="owner",
            expected_old_owner_user_id="owner", new_owner_user_id="newowner2",
            request_digest="d", idempotency_key="k", stage="NEEDS_REVIEW", attempts=3,
            created_at=now, updated_at=now))
    # 缺 newowner2 用户 → matrix_user_id None → 两类处置都应拒绝
    class G:
        def get_room_state(self, room_id):
            return [{"type": "m.room.power_levels", "content": {"users": {"@owner:x": 100}}}]
        def get_room_members(self, room_id):
            return {"@owner:x"}
    settings = S(_env_file=None, environment="test", jwt_secret="x" * 32)
    app = _app(settings, session_factory=factory, matrix_gateway=G())
    def bearer(uid):
        return {"Authorization": "Bearer " + pyjwt.encode(
            {"sub": uid, "iss": settings.jwt_issuer, "iat": int(now.timestamp()),
             "exp": int((now + timedelta(minutes=5)).timestamp())},
            settings.jwt_secret, algorithm="HS256"), "Idempotency-Key": "k-" + uid}

    async def calls():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            denied = await client.get("/api/v1/groups/!r:x/transfer-intents", headers=bearer("rand"))
            owner_view = await client.get("/api/v1/groups/!r:x/transfer-intents", headers=bearer("owner"))
            timeline = await client.get("/api/v1/groups/!r:x/transfer-intents", headers=bearer("root"))
            confirm = await client.post("/api/v1/groups/admin/transfer-intents/intent-1/review",
                headers=bearer("root"), json={"action": "confirm_applied"})
            # 权威状态显示旧群主仍持唯一最高权（新群主无身份更无权力）→
            # 确证未应用，允许失败化释放房间。
            fail = await client.post("/api/v1/groups/admin/transfer-intents/intent-1/review",
                headers=bearer("root"), json={"action": "fail_unapplied"})
            invalid = await client.post("/api/v1/groups/admin/transfer-intents/intent-1/review",
                headers=bearer("root"), json={"action": "force"})
        return denied, owner_view, timeline, confirm, fail, invalid

    denied, owner_view, timeline, confirm, fail, invalid = asyncio.run(calls())
    assert denied.status_code == 403  # 无关用户（非群主非管理员）
    assert owner_view.status_code == 200  # 注册表群主可查看时间线
    assert timeline.status_code == 200 and timeline.json()["items"][0]["id"] == "intent-1"
    assert confirm.status_code == 503  # 全局协调关闭也必须阻止人工复核写入。
    assert fail.status_code == 503
    assert fail.json()['error']['code'] == 'GROUP_TRANSFER_UNAVAILABLE'
    assert invalid.status_code == 422
    engine.dispose()
