"""Immutable declarations of owner-initiated manual-wallet outflows (ADR-0071).

A declaration records an already-executed on-chain transfer; it never creates,
signs or amends a payment. Corrections are appended as linked reversals.
"""
from datetime import datetime
from decimal import Decimal

from sqlalchemy import BigInteger, DateTime, Numeric, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base


class WalletManualOwnerTransfer(Base):
    __tablename__ = "wallet_manual_owner_transfers"
    __table_args__ = (UniqueConstraint("txid", "log_index", name="uq_wallet_owner_transfer_log"),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    txid: Mapped[str] = mapped_column(String(64), nullable=False, index=True)
    log_index: Mapped[int] = mapped_column(BigInteger, nullable=False)
    to_address: Mapped[str] = mapped_column(String(34), nullable=False)
    amount: Mapped[Decimal] = mapped_column(Numeric(30, 6), nullable=False)
    amount_units: Mapped[str] = mapped_column(String(100), nullable=False)
    reason_code: Mapped[str] = mapped_column(String(100), nullable=False)
    reason_detail: Mapped[str] = mapped_column(String(500), nullable=False)
    declared_by: Mapped[str] = mapped_column(String(36), nullable=False)
    digest: Mapped[str] = mapped_column(String(64), nullable=False, unique=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
