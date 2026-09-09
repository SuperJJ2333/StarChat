"""Manual pause ownership and immutable command outcomes."""
from datetime import datetime
from sqlalchemy import JSON, BigInteger, Boolean, CheckConstraint, DateTime, String, event
from sqlalchemy.orm import Mapped, Session, mapped_column
from app.core.database import Base


class WalletManualControlState(Base):
    __tablename__ = 'wallet_manual_control_states'
    __table_args__ = (CheckConstraint('epoch >= 1', name='ck_manual_control_epoch'),)
    id: Mapped[str] = mapped_column(String(20), primary_key=True)
    epoch: Mapped[int] = mapped_column(BigInteger, nullable=False)
    owns_pause: Mapped[bool] = mapped_column(Boolean, nullable=False)
    pause_reason: Mapped[str | None] = mapped_column(String(255))
    owns_safety: Mapped[bool] = mapped_column(Boolean, nullable=False)
    safety_epoch: Mapped[int | None] = mapped_column(BigInteger)
    safety_reason: Mapped[str | None] = mapped_column(String(255))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class WalletManualControlCommand(Base):
    __tablename__ = 'wallet_manual_control_commands'
    idempotency_key: Mapped[str] = mapped_column(String(128), primary_key=True)
    payload_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    result: Mapped[dict] = mapped_column(JSON, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


def _immutable(*args, **kwargs):
    raise ValueError('manual control commands are append-only')


event.listen(WalletManualControlCommand, 'before_update', _immutable)
event.listen(WalletManualControlCommand, 'before_delete', _immutable)


@event.listens_for(Session, 'do_orm_execute')
def _reject_bulk_change(execute_state):
    if execute_state.is_update or execute_state.is_delete:
        table = getattr(execute_state.statement, 'table', None)
        if table is not None and table.name == WalletManualControlCommand.__tablename__:
            _immutable()
