"""Immutable chain facts with separately controlled attribution lifecycle."""
from datetime import datetime
from decimal import Decimal
from sqlalchemy import BigInteger, Boolean, CheckConstraint, DateTime, ForeignKey, Numeric, String, UniqueConstraint, event, inspect
from sqlalchemy.orm import Mapped, mapped_column
from app.core.database import Base


class DepositReceipt(Base):
    __tablename__ = 'wallet_deposit_receipts'
    __table_args__ = (
        UniqueConstraint('network', 'contract', 'txid', 'log_index', name='uq_wallet_deposit_receipt_chain_event'),
        UniqueConstraint('intent_id', name='uq_wallet_deposit_receipt_intent'),
        CheckConstraint("status IN ('REVIEW', 'CREDITED')", name='ck_wallet_deposit_receipt_status'),
        CheckConstraint('amount IS NULL OR amount >= 0', name='ck_wallet_deposit_receipt_amount'),
    )
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    network: Mapped[str] = mapped_column(String(32), nullable=False)
    contract: Mapped[str] = mapped_column(String(128), nullable=False)
    txid: Mapped[str] = mapped_column(String(64), nullable=False)
    log_index: Mapped[int] = mapped_column(nullable=False)
    source_address: Mapped[str] = mapped_column(String(34), nullable=False)
    official_address: Mapped[str] = mapped_column(String(34), nullable=False)
    official_config_version: Mapped[str] = mapped_column(String(128), nullable=False)
    amount_units: Mapped[str] = mapped_column(String(100), nullable=False)
    amount: Mapped[Decimal | None] = mapped_column(Numeric(30, 6))
    block_number: Mapped[int] = mapped_column(BigInteger, nullable=False)
    block_id: Mapped[str] = mapped_column(String(64), nullable=False)
    block_time: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    evidence_policy: Mapped[str] = mapped_column(String(64), nullable=False)
    evidence_source: Mapped[str] = mapped_column(String(64), nullable=False)
    observed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    facts_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    status: Mapped[str] = mapped_column(String(16), nullable=False)
    reason_code: Mapped[str] = mapped_column(String(100), nullable=False)
    pending_obligation: Mapped[bool] = mapped_column(Boolean, nullable=False)
    intent_id: Mapped[str | None] = mapped_column(ForeignKey('wallet_deposit_intents.id'))
    user_id: Mapped[str | None] = mapped_column(String(36))
    ledger_transaction_id: Mapped[str | None] = mapped_column(ForeignKey('wallet_ledger_transactions.id'))


class DepositReceiptAnomaly(Base):
    __tablename__ = 'wallet_deposit_receipt_anomalies'
    __table_args__ = (UniqueConstraint('receipt_id', 'observed_digest', name='uq_wallet_deposit_receipt_anomaly'),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    receipt_id: Mapped[str] = mapped_column(ForeignKey('wallet_deposit_receipts.id'), nullable=False)
    observed_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    reason_code: Mapped[str] = mapped_column(String(100), nullable=False)
    observed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


@event.listens_for(DepositReceipt, 'before_update')
def immutable_receipt(mapper, connection, target):
    state = inspect(target)
    mutable = {'status', 'reason_code', 'pending_obligation', 'intent_id', 'user_id', 'ledger_transaction_id'}
    if any(state.attrs[c.name].history.has_changes() for c in target.__table__.columns if c.name not in mutable):
        raise ValueError('immutable deposit receipt facts')
    changed = state.attrs.status.history
    if (not changed.has_changes() and target.status == 'REVIEW'
            and not any(state.attrs[name].history.has_changes() for name in mutable - {'reason_code'})):
        return
    if (list(changed.deleted) != ['REVIEW'] or target.status != 'CREDITED'
            or target.pending_obligation or not target.intent_id or not target.ledger_transaction_id):
        raise ValueError('immutable deposit receipt lifecycle')


@event.listens_for(DepositReceipt, 'before_delete')
@event.listens_for(DepositReceiptAnomaly, 'before_delete')
@event.listens_for(DepositReceiptAnomaly, 'before_update')
def immutable_record(mapper, connection, target):
    raise ValueError('immutable deposit receipt record')
