from datetime import datetime
from decimal import Decimal
from sqlalchemy import DateTime, ForeignKey, Numeric, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column
from app.core.database import Base

class WalletLedgerTransaction(Base):
    __tablename__ = "wallet_ledger_transactions"
    __table_args__ = (UniqueConstraint("scope", "idempotency_key", name="uq_wallet_ledger_idempotency"),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    asset: Mapped[str] = mapped_column(String(20), nullable=False)
    scope: Mapped[str] = mapped_column(String(80), nullable=False)
    idempotency_key: Mapped[str] = mapped_column(String(128), nullable=False)
    actor_id: Mapped[str] = mapped_column(String(36), nullable=False)
    reason_code: Mapped[str] = mapped_column(String(100), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)

class WalletLedgerEntry(Base):
    __tablename__ = "wallet_ledger_entries"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    transaction_id: Mapped[str] = mapped_column(ForeignKey("wallet_ledger_transactions.id"), nullable=False, index=True)
    account_id: Mapped[str] = mapped_column(String(64), nullable=False, index=True)
    asset: Mapped[str] = mapped_column(String(20), nullable=False)
    amount: Mapped[Decimal] = mapped_column(Numeric(30,6), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)

class Deposit(Base):
    __tablename__ = "wallet_deposits"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    event_id: Mapped[str] = mapped_column(String(128), nullable=False, unique=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    # 链上稳定身份（F03）：按 txid 聚合确认状态；USDT-TRC20 单转账
    # 单 txid，作为链上唯一键。
    txid: Mapped[str] = mapped_column(String(128), nullable=False, unique=True)
    amount: Mapped[Decimal] = mapped_column(Numeric(30,6), nullable=False)
    confirmations: Mapped[int] = mapped_column(nullable=False)
    status: Mapped[str] = mapped_column(String(20), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)

class DepositAddress(Base):
    """A01：充值地址归属持久化——每用户每资产唯一地址，分配后复用。"""
    __tablename__ = "wallet_deposit_addresses"
    __table_args__ = (UniqueConstraint("user_id", "asset", name="uq_wallet_deposit_address_user_asset"),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    asset: Mapped[str] = mapped_column(String(20), nullable=False)
    address: Mapped[str] = mapped_column(String(128), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)

class Withdrawal(Base):
    __tablename__ = "wallet_withdrawals"
    __table_args__ = (UniqueConstraint("user_id", "client_order_id", name="uq_wallet_withdrawal_order"),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    client_order_id: Mapped[str] = mapped_column(String(128), nullable=False)
    address: Mapped[str] = mapped_column(String(128), nullable=False)
    amount: Mapped[Decimal] = mapped_column(Numeric(30,6), nullable=False)
    status: Mapped[str] = mapped_column(String(32), nullable=False)
    finance_approver_id: Mapped[str | None] = mapped_column(String(36))
    admin_approver_id: Mapped[str | None] = mapped_column(String(36))
    provider_txid: Mapped[str | None] = mapped_column(String(128))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)

class WalletControl(Base):
    __tablename__ = "wallet_controls"
    id: Mapped[str] = mapped_column(String(20), primary_key=True)
    withdrawals_paused: Mapped[bool] = mapped_column(nullable=False, default=False)
    pause_reason: Mapped[str | None] = mapped_column(String(255))

class WalletWebhookEvent(Base):
    __tablename__ = "wallet_webhook_events"
    event_id: Mapped[str] = mapped_column(String(128), primary_key=True)
    event_type: Mapped[str] = mapped_column(String(64), nullable=False)
    received_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
