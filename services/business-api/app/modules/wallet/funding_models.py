"""Deposit attribution intentions only; these rows never represent credited money."""
from datetime import datetime
from decimal import Decimal

from sqlalchemy import BigInteger, CheckConstraint, DateTime, ForeignKey, Index, JSON, Numeric, String, UniqueConstraint, event, inspect, text
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base


class DepositIntent(Base):
    __tablename__ = 'wallet_deposit_intents'
    __table_args__ = (
        UniqueConstraint('user_id', 'idempotency_key', name='uq_wallet_deposit_intent_request'),
        Index('uq_wallet_deposit_intent_open', 'user_id', unique=True,
              postgresql_where=text("status = 'OPEN'"), sqlite_where=text("status = 'OPEN'")),
        CheckConstraint("status IN ('OPEN', 'EXPIRED', 'CLOSED_BY_REBIND', 'FULFILLED')", name='ck_wallet_deposit_intent_status'),
        CheckConstraint('expected_amount >= 10 AND binding_version > 0 AND binding_effective_from_block >= 0',
                        name='ck_wallet_deposit_intent_values'),
        CheckConstraint('expires_at > created_at', name='ck_wallet_deposit_intent_expiry'),
        CheckConstraint("(status = 'OPEN' AND closed_at IS NULL) OR (status <> 'OPEN' AND closed_at IS NOT NULL)",
                        name='ck_wallet_deposit_intent_closure'),
    )
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    idempotency_key: Mapped[str] = mapped_column(String(128), nullable=False)
    binding_id: Mapped[str] = mapped_column(ForeignKey('wallet_bindings.id'), nullable=False)
    binding_version: Mapped[int] = mapped_column(nullable=False)
    binding_effective_from_block: Mapped[int] = mapped_column(BigInteger, nullable=False)
    source_address: Mapped[str] = mapped_column(String(34), nullable=False)
    official_address: Mapped[str] = mapped_column(String(34), nullable=False)
    official_config_version: Mapped[str] = mapped_column(String(128), nullable=False)
    network: Mapped[str] = mapped_column(String(32), nullable=False)
    expected_amount: Mapped[Decimal] = mapped_column(Numeric(30, 6), nullable=False)
    rules_snapshot: Mapped[dict] = mapped_column(JSON, nullable=False)
    status: Mapped[str] = mapped_column(String(24), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    closed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


@event.listens_for(DepositIntent, 'before_update')
def _immutable_snapshot(mapper, connection, target):
    state = inspect(target)
    if any(state.attrs[column.name].history.has_changes() for column in target.__table__.columns
           if column.name not in {'status', 'closed_at'}):
        raise ValueError('immutable deposit intent snapshot')
    changed = state.attrs.status.history
    if state.attrs.closed_at.history.has_changes() or changed.has_changes():
        if (list(changed.deleted) != ['OPEN'] or target.status not in {'EXPIRED', 'CLOSED_BY_REBIND', 'FULFILLED'}
                or target.closed_at is None):
            raise ValueError('immutable deposit intent lifecycle')


@event.listens_for(DepositIntent, 'before_delete')
def _no_delete(mapper, connection, target):
    raise ValueError('immutable deposit intent cannot be deleted')
