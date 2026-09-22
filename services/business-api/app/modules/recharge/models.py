"""ADR-0077：人工充值领域模型（客服结算）。

`RechargeRequest` 只是待处理订单——创建绝不增加余额；入账必须经由
既有公开财务服务（审批链不豁免），然后由本模块登记 CREDITED 痕迹。
`evidence_txid` 全局唯一（同一到账凭证不得重复用于充值）。
`CsDirectoryEntry` 是后台授权的官方充值客服目录（收款地址由管理员录入）。
"""
from datetime import datetime
from decimal import Decimal

from sqlalchemy import Boolean, DateTime, ForeignKey, Integer, Numeric, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base


class RechargeRequest(Base):
    __tablename__ = "recharge_requests"
    __table_args__ = (UniqueConstraint("evidence_txid", name="uq_recharge_evidence"),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False, index=True)
    amount_usdt: Mapped[Decimal] = mapped_column(Numeric(30, 6), nullable=False)
    evidence_txid: Mapped[str | None] = mapped_column(String(64), nullable=True)
    note: Mapped[str | None] = mapped_column(String(200), nullable=True)
    status: Mapped[str] = mapped_column(String(16), nullable=False, default="SUBMITTED", index=True)
    # 参考汇率快照（提交时点，仅供展示）
    fx_rate: Mapped[Decimal | None] = mapped_column(Numeric(20, 6), nullable=True)
    fx_rate_stale: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
    # 处理结果
    decided_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    decided_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    decision_reason: Mapped[str | None] = mapped_column(String(200), nullable=True)
    final_rate: Mapped[Decimal | None] = mapped_column(Numeric(20, 6), nullable=True)
    final_caibi_amount: Mapped[Decimal | None] = mapped_column(Numeric(20, 2), nullable=True)
    ledger_transaction_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    adjustment_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class CsDirectoryEntry(Base):
    __tablename__ = "cs_directory_entries"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    cs_user_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)
    display_name: Mapped[str] = mapped_column(String(64), nullable=False)
    payment_address: Mapped[str] = mapped_column(String(128), nullable=False)
    note: Mapped[str | None] = mapped_column(String(200), nullable=True)
    enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    sort: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class RechargeCreditBinding(Base):
    """ADR-0077 实施补充：充值案件与唯一授权财务命令的持久绑定。

    一个案件同一时刻至多一个活动绑定；不确定的已执行金额进入
    NEEDS_REVIEW 并继续占用。拒绝或已冲正才释放为 FAILED；登记与
    REGISTERED 同事务提交，终态 NULL 允许保留多次历史。
    """
    __tablename__ = "recharge_credit_bindings"
    __table_args__ = (
        UniqueConstraint("request_id", "state_active", name="uq_recharge_binding_active_request"),
        UniqueConstraint("adjustment_id", "state_active", name="uq_recharge_binding_active_adjustment"),
    )
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    request_id: Mapped[str] = mapped_column(String(36), ForeignKey("recharge_requests.id"), nullable=False, index=True)
    adjustment_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    state: Mapped[str] = mapped_column(String(16), nullable=False, default="BOUND")
    # NULL permits multiple historical rows; unresolved financial facts stay active.
    state_active: Mapped[str | None] = mapped_column(String(1), nullable=True, default="1")
    final_rate: Mapped[Decimal | None] = mapped_column(Numeric(20, 6), nullable=True)
    final_caibi_amount: Mapped[Decimal | None] = mapped_column(Numeric(20, 2), nullable=True)
    bound_by: Mapped[str] = mapped_column(String(36), nullable=False)
    failure_reason: Mapped[str | None] = mapped_column(String(200), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
