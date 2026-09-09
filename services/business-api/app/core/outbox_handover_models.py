"""Append-only reservations, actual notice receipts and original-event dispositions."""
from datetime import datetime
from sqlalchemy import JSON, DateTime, String, event
from sqlalchemy.orm import Mapped, Session, mapped_column
from app.core.database import Base


class OutboxHandoverNotice(Base):
    __tablename__ = 'outbox_handover_notices'
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    preparation_id: Mapped[str] = mapped_column(String(36), unique=True, nullable=False)
    manifest_digest: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    payload_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    actor_id: Mapped[str] = mapped_column(String(36), nullable=False)
    reason_code: Mapped[str] = mapped_column(String(100), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class OutboxHandoverMember(Base):
    __tablename__ = 'outbox_handover_members'
    event_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    notice_id: Mapped[str] = mapped_column(String(36), nullable=False)
    original_snapshot: Mapped[dict] = mapped_column(JSON, nullable=False)
    manifest_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class OutboxHandoverReceipt(Base):
    __tablename__ = 'outbox_handover_receipts'
    notice_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    payload_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    transport: Mapped[str] = mapped_column(String(16), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class OutboxHandoverDisposition(Base):
    __tablename__ = 'outbox_handover_dispositions'
    event_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    notice_id: Mapped[str] = mapped_column(String(36), nullable=False)
    manifest_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    disposition: Mapped[str] = mapped_column(String(40), nullable=False)
    actor_id: Mapped[str] = mapped_column(String(36), nullable=False)
    reason_code: Mapped[str] = mapped_column(String(100), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


_MODELS = (OutboxHandoverNotice, OutboxHandoverMember, OutboxHandoverReceipt, OutboxHandoverDisposition)


def _immutable(*args, **kwargs):
    raise ValueError('outbox handover evidence is append-only')


for _model in _MODELS:
    event.listen(_model, 'before_update', _immutable)
    event.listen(_model, 'before_delete', _immutable)


@event.listens_for(Session, 'do_orm_execute')
def _reject_bulk_change(state):
    if state.is_update or state.is_delete:
        table = getattr(state.statement, 'table', None)
        if table is not None and table.name in {model.__tablename__ for model in _MODELS}:
            _immutable()
