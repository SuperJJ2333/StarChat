"""ADR-0079：业务群注册表服务（群主任期与财务受益人权威）。

权威关系：
- 财务受益人（红包抽成）与转让任期 = 本注册表（业务 user id）；
- 房间操作控制 = Matrix 权限（power levels）。
直接修改 Matrix 权限不能变更注册表——冷却与抽成权益不被绕过。

注册来源：
1. 建群注册：`register_creation`（客户端建群后调用；核验发起者当前
   power ≥ CREATOR_POWER 后落行，owner_since=now）。
2. 旧群被动发现：`ensure`——按 power levels 解析群主落行，
   `owner_since=NULL`（任期不可证明：不用最近活跃时间、不臆造 30 天）。
3. 管理员审计迁移：`admin_set_tenure`（强制原因，逐案人工核证）。

转让（`transfer`）：joined ≥ COOLDOWN_MIN_MEMBERS 时要求
`owner_since` 非空且 now − owner_since ≥ COOLDOWN_PERIOD（服务端 UTC
30×24h 精确比较）；并发转让以条件更新（`WHERE owner_user_id=:old`）
保证只有一个赢家；失败/重试不提前变更接任时间。
"""
from datetime import datetime, timedelta, timezone
from uuid import uuid4
from contextlib import nullcontext

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from app.modules.groups.models import BusinessGroup

CREATOR_POWER = 100
COOLDOWN_PERIOD = timedelta(days=30)
COOLDOWN_MIN_MEMBERS = 10
RULES_VERSION = "group-owner-v1"


class GroupOwnerError(ValueError):
    """携带稳定业务码的群主域错误（API 层映射为 HTTP 错误）。"""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def parse_power_level_users(state_events: list[dict]) -> dict[str, int]:
    for event in state_events or []:
        if event.get("type") == "m.room.power_levels":
            users = (event.get("content") or {}).get("users")
            if isinstance(users, dict):
                return {str(k): int(v) for k, v in users.items() if isinstance(v, (int, float))}
            return {}
    return {}


def matrix_owner_from_state(state_events: list[dict]) -> str | None:
    """群主口径：power ≥ CREATOR_POWER 的唯一最高权者（创建者口径）。"""
    users = parse_power_level_users(state_events)
    if not users:
        return None
    top_power = max(users.values())
    if top_power < CREATOR_POWER:
        return None
    holders = sorted(user for user, power in users.items() if power == top_power)
    if len(holders) != 1:
        return None
    return holders[0]


class GroupRegistryService:
    def __init__(self, session_factory, *, matrix_gateway, now=None):
        self._factory = session_factory
        self._gateway = matrix_gateway
        self._now = now or (lambda: datetime.now(timezone.utc))

    def _utcnow(self) -> datetime:
        value = self._now()
        return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)

    # ------------------------------------------------------------------ 查询
    def matrix_user_id(self, user_id: str) -> str | None:
        """业务 user id → Matrix id（协调器与视图共用）。"""
        with self._factory() as session:
            return self._matrix_user_id(session, user_id)

    def get(self, room_id: str) -> BusinessGroup | None:
        with self._factory() as session:
            return session.scalar(select(BusinessGroup).where(BusinessGroup.room_id == room_id))

    def owner_of(self, room_id: str) -> str | None:
        row = self.get(room_id) or self.ensure(room_id)
        return row.owner_user_id if row else None

    def owner_for_creation(self, session, room_id: str) -> str:
        """Freeze the financial beneficiary under the packet creation transaction."""
        return self.ensure(room_id, session=session).owner_user_id

    def group_view(self, room_id: str) -> dict | None:
        """群信息投影：注册表群主 + Matrix 权群主 + desync 标记。
        比较统一在 Matrix user id 维度（业务 id ≠ Matrix id）。"""
        row = self.get(room_id)
        if row is None:
            return None
        with self._factory() as session:
            owner_matrix_id = self._matrix_user_id(session, row.owner_user_id)
        try:
            matrix_owner = matrix_owner_from_state(self._gateway.get_room_state(room_id))
            authority_available = True
        except Exception:
            matrix_owner, authority_available = None, False
        return {
            "room_id": room_id,
            "owner_user_id": row.owner_user_id,
            "owner_matrix_id": owner_matrix_id,
            "owner_since": row.owner_since,
            "tenure_source": row.tenure_source,
            "matrix_power_owner": matrix_owner,
            "owner_desync": authority_available and (matrix_owner is None or matrix_owner != owner_matrix_id),
            "owner_authority_available": authority_available,
            "rules_version": RULES_VERSION,
        }

    # ------------------------------------------------------------------ 注册
    def _resolve_matrix_owner(self, requester_matrix_id: str | None, room_id: str) -> str | None:
        try:
            state_events = self._gateway.get_room_state(room_id)
        except Exception:
            return None
        return matrix_owner_from_state(state_events)

    def _matrix_user_id(self, session, user_id: str) -> str | None:
        from app.modules.identity.models import User

        return session.scalar(select(User.matrix_user_id).where(User.id == user_id))

    def ensure(self, room_id: str, *, fallback_owner_user_id: str | None = None, session=None) -> BusinessGroup:
        """读取或被动注册（旧群首次触达）。owner 与 owner_since 均可能为
        不可证明状态：owner 取 Matrix 权群主解析的业务用户；owner_since=NULL。"""
        with (self._factory.begin() if session is None else nullcontext(session)) as session:
            row = session.scalar(select(BusinessGroup).where(BusinessGroup.room_id == room_id).with_for_update())
            if row is not None:
                return row
            matrix_owner_matrix_id = self._resolve_matrix_owner(None, room_id)
            owner_user_id = None
            if matrix_owner_matrix_id:
                from app.modules.identity.models import User
                from app.modules.identity.enums import AccountStatus
                try:
                    members = set(self._gateway.get_room_members(room_id))
                except Exception:
                    raise GroupOwnerError("GROUP_AUTHORITY_UNAVAILABLE", "群成员权威不可用") from None
                if matrix_owner_matrix_id in members:
                    owner_user_id = session.scalar(select(User.id).where(
                        User.matrix_user_id == matrix_owner_matrix_id, User.status == AccountStatus.ACTIVE))
            if owner_user_id is None:
                raise GroupOwnerError("GROUP_OWNER_UNRESOLVABLE", "无法从权威来源解析群主")
            now = self._utcnow()
            row = BusinessGroup(room_id=room_id, owner_user_id=owner_user_id, owner_since=None,
                tenure_source=None, created_at=now, updated_at=now)
            session.add(row)
            try:
                session.flush()
            except IntegrityError:
                raise GroupOwnerError("GROUP_OWNER_UNRESOLVABLE", "群主并发注册冲突") from None
            return row

    def register_creation(self, room_id: str, registrant_user_id: str) -> BusinessGroup:
        """新群注册：核验发起者当前 power ≥ CREATOR_POWER（服务端可信来源），
        owner_since = 注册成功时间（建群成为群主的时间）。"""
        with self._factory.begin() as session:
            existing = session.scalar(select(BusinessGroup).where(BusinessGroup.room_id == room_id).with_for_update())
            if existing is not None:
                if existing.owner_user_id != registrant_user_id or existing.tenure_source != "creation":
                    raise GroupOwnerError("GROUP_ALREADY_REGISTERED", "该群已注册群主")
                return existing
            registrant_matrix_id = self._matrix_user_id(session, registrant_user_id)
            try:
                state_events = self._gateway.get_room_state(room_id)
            except Exception:
                raise GroupOwnerError("GROUP_AUTHORITY_UNAVAILABLE", "群权限权威不可用") from None
            users = parse_power_level_users(state_events)
            power = users.get(registrant_matrix_id or "", 0)
            try:
                members = set(self._gateway.get_room_members(room_id))
            except Exception:
                raise GroupOwnerError("GROUP_AUTHORITY_UNAVAILABLE", "群成员权威不可用") from None
            if (power < CREATOR_POWER or registrant_matrix_id not in members
                    or matrix_owner_from_state(state_events) != registrant_matrix_id):
                raise GroupOwnerError("GROUP_CREATOR_POWER_REQUIRED", "只有群创建者可以注册群主任期")
            now = self._utcnow()
            row = BusinessGroup(room_id=room_id, owner_user_id=registrant_user_id, owner_since=now,
                tenure_source="creation", created_at=now, updated_at=now)
            session.add(row)
            session.flush()
            return row

    def admin_set_tenure(self, room_id: str, *, owner_since: datetime, reason_code: str, actor_id: str) -> BusinessGroup:
        """管理员审计迁移：旧群任期补录（需用户逐案决定，强制原因）。"""
        from app.modules.audit.models import AuditEvent

        if not reason_code or not reason_code.strip():
            raise GroupOwnerError("GROUP_TENURE_REASON_REQUIRED", "任期迁移必须记录原因")
        with self._factory.begin() as session:
            row = session.scalar(select(BusinessGroup).where(BusinessGroup.room_id == room_id).with_for_update())
            if row is None:
                raise GroupOwnerError("GROUP_NOT_REGISTERED", "群未注册")
            row.owner_since = owner_since if owner_since.tzinfo else owner_since.replace(tzinfo=timezone.utc)
            row.tenure_source = "admin_migration"
            row.updated_at = self._utcnow()
            session.add(AuditEvent(id=str(uuid4()), actor_id=actor_id, subject_type="business_group",
                subject_id=room_id, action="group.owner_tenure_migrated", result="SUCCESS",
                reason_code=reason_code[:100], trace_id=str(uuid4().hex[:32]),
                after_data={"owner_since": row.owner_since.isoformat()}, created_at=self._utcnow()))
            session.flush()
            return row

    # ------------------------------------------------------------------ 转让
    def joined_member_count(self, room_id: str) -> int:
        """joined 成员数（含群主，不含待接受邀请）——服务端权威快照。"""
        try:
            return len(self._gateway.get_room_members(room_id))
        except Exception:
            raise GroupOwnerError("GROUP_AUTHORITY_UNAVAILABLE", "群成员权威不可用") from None

    def transfer(self, room_id: str, *, current_owner_user_id: str, new_owner_user_id: str,
                 matrix_power_applied=None) -> BusinessGroup:
        """群主转让：冷却校验（服务端 UTC）+ 条件更新单赢家。

        `matrix_power_applied(session, new_owner_matrix_id)` 允许调用方在
        同一业务事务内登记 Matrix 侧变更凭据（可选；成功后才提交）。
        Matrix 变更本身由客户端在转让成功后执行；注册表是财务权威。
        """
        joined = self.joined_member_count(room_id)
        with self._factory.begin() as session:
            row = session.scalar(select(BusinessGroup).where(BusinessGroup.room_id == room_id).with_for_update())
            if row is None:
                raise GroupOwnerError("GROUP_NOT_REGISTERED", "群未注册")
            if row.owner_user_id != current_owner_user_id:
                raise GroupOwnerError("GROUP_OWNER_MISMATCH", "只有当前群主可以发起转让")
            if current_owner_user_id == new_owner_user_id:
                raise GroupOwnerError("GROUP_TRANSFER_TARGET_INVALID", "新群主不能是当前群主")
            if joined >= COOLDOWN_MIN_MEMBERS:
                if row.owner_since is None:
                    raise GroupOwnerError("OWNER_TENURE_UNPROVEN",
                        "该群已满10人，但当前群主任期无法证明，转让暂不受理")
                held = self._utcnow() - (row.owner_since if row.owner_since.tzinfo else row.owner_since.replace(tzinfo=timezone.utc))
                if held < COOLDOWN_PERIOD:
                    remaining = COOLDOWN_PERIOD - held
                    raise GroupOwnerError("OWNER_TENURE_INSUFFICIENT",
                        f"满10人的群群主需任满30天才能转让，剩余约 {int(remaining.total_seconds() // 86400) + 1} 天")
            if session.scalar(select(BusinessGroup.owner_user_id).where(
                    BusinessGroup.room_id == room_id)) is None:
                raise GroupOwnerError("GROUP_NOT_REGISTERED", "群未注册")
            new_owner_matrix_id = self._matrix_user_id(session, new_owner_user_id)
            if not new_owner_matrix_id:
                raise GroupOwnerError("GROUP_TRANSFER_TARGET_INVALID", "新群主缺少权威身份")
            from app.modules.identity.models import User
            from app.modules.identity.enums import AccountStatus
            current_matrix_id = self._matrix_user_id(session, current_owner_user_id)
            try:
                members = set(self._gateway.get_room_members(room_id))
                authority = matrix_owner_from_state(self._gateway.get_room_state(room_id))
            except Exception:
                raise GroupOwnerError("GROUP_AUTHORITY_UNAVAILABLE", "群权限权威不可用") from None
            if current_matrix_id not in members or authority != current_matrix_id:
                raise GroupOwnerError("GROUP_OWNER_AUTHORITY_MISMATCH", "群主权限与业务记录不一致")
            if (new_owner_matrix_id not in members or session.scalar(select(User.status).where(
                    User.id == new_owner_user_id)) != AccountStatus.ACTIVE):
                raise GroupOwnerError("GROUP_TRANSFER_TARGET_INVALID", "新群主必须是当前有效群成员")
            now = self._utcnow()
            updated = session.execute(
                _conditional_owner_update(room_id, current_owner_user_id, new_owner_user_id, now))
            if updated.rowcount != 1:
                raise GroupOwnerError("GROUP_TRANSFER_CONCURRENT", "转让已被并发请求完成")
            if matrix_power_applied is not None:
                matrix_power_applied(session, new_owner_matrix_id)
            session.flush()
            row = session.scalar(select(BusinessGroup).where(BusinessGroup.room_id == room_id))
            return row


def _conditional_owner_update(room_id, old_owner, new_owner, now):
    from sqlalchemy import update

    return update(BusinessGroup).where(
        BusinessGroup.room_id == room_id, BusinessGroup.owner_user_id == old_owner
    ).values(owner_user_id=new_owner, owner_since=now, tenure_source="transfer", updated_at=now)
