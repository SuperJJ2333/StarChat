from datetime import date, datetime
from decimal import Decimal

from sqlalchemy import Date, DateTime, JSON, Numeric, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base

class AdjustmentPolicy(Base):
    __tablename__ = "adjustment_policies"
    actor_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    per_transaction: Mapped[Decimal] = mapped_column(Numeric(20, 2), nullable=False)
    per_day: Mapped[Decimal] = mapped_column(Numeric(20, 2), nullable=False)
    allowed_users: Mapped[list[str]] = mapped_column(JSON, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)

class AdjustmentRequest(Base):
    __tablename__ = "adjustment_requests"
    __table_args__ = (UniqueConstraint("submitted_by", "idempotency_key", name="uq_adjustment_submit_idempotency"),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    amount: Mapped[Decimal] = mapped_column(Numeric(20, 2), nullable=False)
    reason_code: Mapped[str] = mapped_column(String(100), nullable=False)
    status: Mapped[str] = mapped_column(String(30), nullable=False)
    submitted_by: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    idempotency_key: Mapped[str] = mapped_column(String(128), nullable=False)
    finance_reviewer_id: Mapped[str | None] = mapped_column(String(36))
    admin_reviewer_id: Mapped[str | None] = mapped_column(String(36))
    ledger_transaction_id: Mapped[str | None] = mapped_column(String(36))
    business_date: Mapped[date] = mapped_column(Date, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
