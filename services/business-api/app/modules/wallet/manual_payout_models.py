"""Immutable manual payout terms and auditable one-way execution state."""
from datetime import datetime
from decimal import Decimal

from sqlalchemy import JSON, CheckConstraint, DateTime, ForeignKey, Numeric, String, UniqueConstraint, event, inspect
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base


class ManualPayoutQuote(Base):
    __tablename__ = 'wallet_manual_payout_quotes'
    __table_args__ = (CheckConstraint('amount >= 10', name='ck_manual_quote_amount'),
        CheckConstraint('expires_at > created_at', name='ck_manual_quote_expiry'))
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    amount: Mapped[Decimal] = mapped_column(Numeric(30, 6), nullable=False)
    snapshot: Mapped[dict] = mapped_column(JSON, nullable=False)
    digest: Mapped[str] = mapped_column(String(64), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class ManualPayoutOrder(Base):
    __tablename__ = 'wallet_manual_payout_orders'
    __table_args__ = (CheckConstraint("status IN ('REQUESTED','CLAIMED','UNKNOWN','SETTLED','CANCELLED')", name='ck_manual_payout_status'),
        CheckConstraint('amount >= 10', name='ck_manual_payout_amount'),
        CheckConstraint("(status IN ('REQUESTED','CANCELLED') AND claimed_by IS NULL AND claimed_at IS NULL AND candidate_txid IS NULL) OR (status IN ('CLAIMED','UNKNOWN','SETTLED') AND claimed_by IS NOT NULL AND claimed_at IS NOT NULL)", name='ck_manual_payout_claim'),
        CheckConstraint("candidate_txid IS NULL OR status IN ('UNKNOWN','SETTLED')", name='ck_manual_payout_candidate'),
        CheckConstraint("status != 'SETTLED' OR candidate_txid IS NOT NULL", name='ck_manual_payout_settled'))
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    quote_id: Mapped[str] = mapped_column(ForeignKey('wallet_manual_payout_quotes.id'), unique=True, nullable=False)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    amount: Mapped[Decimal] = mapped_column(Numeric(30, 6), nullable=False)
    digest: Mapped[str] = mapped_column(String(64), nullable=False)
    status: Mapped[str] = mapped_column(String(16), nullable=False)
    claimed_by: Mapped[str | None] = mapped_column(String(36))
    claimed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    candidate_txid: Mapped[str | None] = mapped_column(String(64))
    review_reason: Mapped[str | None] = mapped_column(String(80))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class ManualPayoutCommand(Base):
    __tablename__ = 'wallet_manual_payout_commands'
    __table_args__ = (UniqueConstraint('actor_id', 'operation', 'idempotency_key', name='uq_manual_payout_command'),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    actor_id: Mapped[str] = mapped_column(String(36), nullable=False)
    operation: Mapped[str] = mapped_column(String(24), nullable=False)
    idempotency_key: Mapped[str] = mapped_column(String(128), nullable=False)
    digest: Mapped[str] = mapped_column(String(64), nullable=False)
    response: Mapped[dict] = mapped_column(JSON, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class ManualPayoutEvent(Base):
    __tablename__ = 'wallet_manual_payout_events'
    __table_args__ = (UniqueConstraint('network', 'contract', 'txid', 'log_index', name='uq_manual_payout_event'),
        CheckConstraint('log_index >= 0', name='ck_manual_payout_log_index'))
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    order_id: Mapped[str] = mapped_column(ForeignKey('wallet_manual_payout_orders.id'), unique=True, nullable=False)
    network: Mapped[str] = mapped_column(String(32), nullable=False)
    contract: Mapped[str] = mapped_column(String(34), nullable=False)
    txid: Mapped[str] = mapped_column(String(64), nullable=False)
    log_index: Mapped[int] = mapped_column(nullable=False)
    evidence: Mapped[dict] = mapped_column(JSON, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class ManualPayoutCandidate(Base):
    __tablename__ = 'wallet_manual_payout_candidates'
    __table_args__ = (UniqueConstraint('order_id', 'txid', name='uq_manual_payout_candidate'),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    order_id: Mapped[str] = mapped_column(ForeignKey('wallet_manual_payout_orders.id'), nullable=False)
    txid: Mapped[str] = mapped_column(String(64), nullable=False)
    actor_id: Mapped[str] = mapped_column(String(36), nullable=False)
    reason_code: Mapped[str] = mapped_column(String(80), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


def _immutable(mapper, connection, target):
    raise ValueError('manual payout evidence is immutable')


for _model in (ManualPayoutQuote, ManualPayoutCommand, ManualPayoutEvent, ManualPayoutCandidate):
    event.listen(_model, 'before_update', _immutable)
    event.listen(_model, 'before_delete', _immutable)
event.listen(ManualPayoutOrder, 'before_delete', _immutable)


@event.listens_for(ManualPayoutOrder, 'before_update')
def _guard_order(mapper, connection, target):
    state = inspect(target)
    status_history = state.attrs.status.history
    previous_status = status_history.deleted[0] if status_history.deleted else target.status
    if previous_status in {'SETTLED', 'CANCELLED'} and any(attr.history.has_changes() for attr in state.attrs):
        raise ValueError('illegal terminal manual payout mutation')
    for field in ('id', 'quote_id', 'user_id', 'amount', 'digest', 'created_at'):
        if state.attrs[field].history.has_changes():
            raise ValueError('manual payout snapshot is immutable')
    for field in ('claimed_by', 'claimed_at', 'candidate_txid'):
        history = state.attrs[field].history
        if history.has_changes() and history.deleted and history.deleted[0] is not None:
            raise ValueError('manual payout claim is immutable')
    history = state.attrs.status.history
    if history.has_changes() and history.deleted:
        allowed = {'REQUESTED': {'CLAIMED', 'CANCELLED'}, 'CLAIMED': {'UNKNOWN', 'SETTLED'},
            'UNKNOWN': {'SETTLED'}, 'SETTLED': set(), 'CANCELLED': set()}
        if target.status not in allowed[history.deleted[0]]:
            raise ValueError('illegal manual payout transition')
