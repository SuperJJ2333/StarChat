"""群红包房间成员授权（审计 F06）。

Matrix 是群成员关系的唯一权威来源（见 groups/models.py 模块注释——业务库
不复制成员关系）。本模块把"业务用户是否属于房间"的判定收敛为一个可注入
RedPacketService 的权威对象：

- 由业务 users 表解析用户的 Matrix ID；
- 经 Synapse admin API 读取房间当前 join 成员（仅成员元数据，绝不读取
  消息正文——E2EE 边界不受影响）；
- 退群/被踢后不再是 join 成员 → 不可见、不可领（fail closed）；
- 网关不可达/用户无 Matrix ID → 拒绝（无法证明成员身份即无权限）。
"""
from typing import Protocol

from sqlalchemy import select


class RoomMembershipAuthority(Protocol):
    def is_member(self, room_id: str, user_id: str) -> bool: ...


class MatrixRoomMembershipAuthority:
    def __init__(self, session_factory, gateway) -> None:
        self._session_factory = session_factory
        self._gateway = gateway

    def matrix_user_id(self, user_id: str) -> str | None:
        from app.modules.identity.models import User

        with self._session_factory() as session:
            return session.scalar(
                select(User.matrix_user_id).where(User.id == user_id)
            )

    def is_member(self, room_id: str, user_id: str) -> bool:
        matrix_id = self.matrix_user_id(user_id)
        if not matrix_id:
            return False
        try:
            members = self._gateway.get_room_members(room_id)
        except Exception:
            # 权威源不可达：fail closed（不得在无法验证成员身份时放行）。
            return False
        return matrix_id in members


class StaticRoomMembershipAuthority:
    """测试替身：显式成员集合。"""

    def __init__(self, members_by_room: dict[str, set[str]] | None = None):
        self._members_by_room = members_by_room or {}

    def set_members(self, room_id: str, members: set[str]) -> None:
        self._members_by_room[room_id] = set(members)

    def is_member(self, room_id: str, user_id: str) -> bool:
        return user_id in self._members_by_room.get(room_id, set())
