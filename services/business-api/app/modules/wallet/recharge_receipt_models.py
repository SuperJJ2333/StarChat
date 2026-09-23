"""Wallet-owned receipt reservations consumed only by approved CAIBI settlement."""
from datetime import datetime
from sqlalchemy import DateTime, ForeignKey, String, event, inspect
from sqlalchemy.orm import Mapped, mapped_column
from app.core.database import Base

class RechargeReceiptReservation(Base):
    __tablename__='wallet_recharge_receipt_reservations'
    receipt_id: Mapped[str] = mapped_column(ForeignKey('wallet_deposit_receipts.id'),primary_key=True)
    request_id: Mapped[str] = mapped_column(String(36),nullable=False,unique=True)
    user_id: Mapped[str] = mapped_column(String(36),nullable=False)
    state: Mapped[str] = mapped_column(String(16),nullable=False)
    facts_digest: Mapped[str] = mapped_column(String(64),nullable=False)
    verified_at: Mapped[datetime] = mapped_column(DateTime(timezone=True),nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True),nullable=False)
    ledger_transaction_id: Mapped[str | None] = mapped_column(String(36),unique=True)


@event.listens_for(RechargeReceiptReservation, 'before_update')
def immutable_reservation_identity(mapper, connection, target):
    state = inspect(target)
    mutable = {'verified_at', 'state', 'ledger_transaction_id'}
    if any(state.attrs[column.name].history.has_changes()
           for column in target.__table__.columns if column.name not in mutable):
        raise ValueError('immutable support receipt reservation identity')
    old_state = state.attrs.state.history.deleted
    if target.state == 'RESERVED' and not old_state and target.ledger_transaction_id is None:
        return
    if (list(old_state) == ['RESERVED'] and target.state == 'CONSUMED'
            and target.ledger_transaction_id and not state.attrs.verified_at.history.has_changes()):
        return
    raise ValueError('immutable support receipt reservation lifecycle')


@event.listens_for(RechargeReceiptReservation, 'before_delete')
def immutable_reservation_delete(mapper, connection, target):
    raise ValueError('immutable support receipt reservation history')
