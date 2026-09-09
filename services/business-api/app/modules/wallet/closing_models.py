"""Append-only captured-entry-set closes; never financial period mutation."""
from datetime import date, datetime

from sqlalchemy import JSON, Date, DateTime, ForeignKey, Integer, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base


class WalletDailyClose(Base):
    __tablename__ = 'wallet_daily_closes'
    __table_args__ = (
        UniqueConstraint('day', 'revision', name='uq_wallet_close_day_revision'),
        UniqueConstraint('idempotency_key', name='uq_wallet_close_idempotency'),
    )
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    day: Mapped[date] = mapped_column(Date, nullable=False)
    revision: Mapped[int] = mapped_column(Integer, nullable=False)
    previous_id: Mapped[str | None] = mapped_column(ForeignKey('wallet_daily_closes.id'))
    digest: Mapped[str] = mapped_column(String(64), nullable=False)
    report: Mapped[dict] = mapped_column(JSON, nullable=False)
    created_by: Mapped[str] = mapped_column(String(36), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    reason_code: Mapped[str] = mapped_column(String(100), nullable=False)
    idempotency_key: Mapped[str] = mapped_column(String(128), nullable=False)
