"""Persistent source ownership for the global redeemable outgoing restriction."""
from datetime import datetime
from sqlalchemy import BigInteger, Boolean, CheckConstraint, DateTime, String
from sqlalchemy.orm import Mapped, mapped_column
from app.core.database import Base


class LedgerOutgoingRestriction(Base):
    __tablename__ = 'ledger_outgoing_restrictions'
    __table_args__ = (CheckConstraint('epoch >= 1', name='ck_ledger_restriction_epoch'),)
    scope: Mapped[str] = mapped_column(String(64), primary_key=True)
    active: Mapped[bool] = mapped_column(Boolean, nullable=False)
    epoch: Mapped[int] = mapped_column(BigInteger, nullable=False)
    reason_code: Mapped[str] = mapped_column(String(100), nullable=False)
    actor_id: Mapped[str] = mapped_column(String(36), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
