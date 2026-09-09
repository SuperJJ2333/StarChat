"""Durable discovery watermark and retryable transaction inbox."""
from datetime import datetime
from sqlalchemy import BigInteger, CheckConstraint, DateTime, Integer, String
from sqlalchemy.orm import Mapped, mapped_column
from app.core.database import Base


class WalletFundingScanState(Base):
    __tablename__ = 'wallet_funding_scan_state'
    __table_args__ = (CheckConstraint('cursor_rowid >= 0 AND source_max_rowid >= cursor_rowid AND checkpoint_ms >= 0', name='ck_funding_scan_cursor'),)
    id: Mapped[str] = mapped_column(String(20), primary_key=True)
    source_identity: Mapped[str] = mapped_column(String(64), nullable=False)
    cursor_rowid: Mapped[int] = mapped_column(BigInteger, nullable=False)
    source_max_rowid: Mapped[int] = mapped_column(BigInteger, nullable=False)
    checkpoint_ms: Mapped[int] = mapped_column(BigInteger, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class WalletFundingScanItem(Base):
    __tablename__ = 'wallet_funding_scan_items'
    __table_args__ = (CheckConstraint("state IN ('PENDING','PROCESSED','RETRY')", name='ck_funding_scan_item_state'),
        CheckConstraint('discovered_rowid > 0 AND attempts >= 0', name='ck_funding_scan_item_progress'))
    txid: Mapped[str] = mapped_column(String(64), primary_key=True)
    state: Mapped[str] = mapped_column(String(16), nullable=False)
    discovered_rowid: Mapped[int] = mapped_column(BigInteger, nullable=False)
    attempts: Mapped[int] = mapped_column(Integer, nullable=False)
    last_reason: Mapped[str | None] = mapped_column(String(80))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
