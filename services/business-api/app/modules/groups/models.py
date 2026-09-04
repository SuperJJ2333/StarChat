"""群聊加入领域模型（群二维码令牌 + 入群审批）。

Matrix 仍是群成员关系的唯一权威来源——本模块只保存加入凭据与审批
状态，不复制成员关系。令牌明文绝不出现在数据库或日志（只存 sha256）。
"""
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base


class GroupJoinToken(Base):
    __tablename__ = "group_join_tokens"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    room_id: Mapped[str] = mapped_column(String(255), index=True)
    creator_user_id: Mapped[str] = mapped_column(ForeignKey("users.id"))
    token_hash: Mapped[str] = mapped_column(String(64), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class GroupJoinRequest(Base):
    __tablename__ = "group_join_requests"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    room_id: Mapped[str] = mapped_column(String(255), index=True)
    requester_user_id: Mapped[str] = mapped_column(ForeignKey("users.id"))
    token_id: Mapped[str | None] = mapped_column(
        ForeignKey("group_join_tokens.id")
    )
    status: Mapped[str] = mapped_column(String(20))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    decided_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    decider_user_id: Mapped[str | None] = mapped_column(ForeignKey("users.id"))
