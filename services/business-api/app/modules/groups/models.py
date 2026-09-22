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


class BusinessGroup(Base):
    """ADR-0079：业务群注册表——财务受益人（群主抽成）与转让任期的权威来源。

    Matrix 权限仍是房间操作控制的权威；直接改 Matrix 权限不能变更本表，
    因此不能绕过冷却获得新群主任期、也不能改变抽成受益人（红包创建时
    从本表锁定 beneficiary）。`owner_since` 为 NULL 表示任期无法证明
    （旧群被动发现），仅审计路径可补录。
    """
    __tablename__ = "business_groups"

    room_id: Mapped[str] = mapped_column(String(255), primary_key=True)
    owner_user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), nullable=False)
    owner_since: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    tenure_source: Mapped[str | None] = mapped_column(String(24), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class GroupTransferIntent(Base):
    """ADR-0079 实施补充：群主转让的持久可恢复操作意图。

    阶段机：VALIDATED（领域校验通过）→ MATRIX_PENDING（认领并正在应用
    Matrix power level）→ MATRIX_APPLIED（权威状态确认）→ COMPLETED
    （财务注册表已原子换主）。发送结果不确定保留 MATRIX_PENDING；恢复
    只读确认，无法证实则 NEEDS_REVIEW，不重发或擅自回滚 Matrix 事实。
    """
    __tablename__ = "group_transfer_intents"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    room_id: Mapped[str] = mapped_column(String(255), nullable=False, index=True)
    requester_user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    expected_old_owner_user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    new_owner_user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    request_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    idempotency_key: Mapped[str] = mapped_column(String(128), nullable=False, unique=True)
    stage: Mapped[str] = mapped_column(String(20), nullable=False, default="VALIDATED", index=True)
    attempts: Mapped[int] = mapped_column(nullable=False, default=0)
    claim_token: Mapped[str | None] = mapped_column(String(64), nullable=True)
    claim_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    last_error_code: Mapped[str | None] = mapped_column(String(64), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
