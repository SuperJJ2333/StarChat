"""Immutable exact-state handover preparations, commands and incident dispositions."""
from datetime import datetime
from sqlalchemy import JSON, DateTime, Integer, String, UniqueConstraint, event
from sqlalchemy.orm import Mapped, Session, mapped_column
from app.core.database import Base


class WalletHandoverPreparation(Base):
    __tablename__ = 'wallet_handover_preparations'
    __table_args__ = (UniqueConstraint('actor_id', 'idempotency_key', name='uq_wallet_handover_prepare'),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    actor_id: Mapped[str] = mapped_column(String(36), nullable=False)
    idempotency_key: Mapped[str] = mapped_column(String(128), nullable=False)
    payload_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    manifest_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    manifest: Mapped[dict] = mapped_column(JSON, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class WalletHandoverCommand(Base):
    __tablename__ = 'wallet_handover_commands'
    idempotency_key: Mapped[str] = mapped_column(String(128), primary_key=True)
    payload_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    result: Mapped[dict] = mapped_column(JSON, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class WalletIncidentHandoverDisposition(Base):
    __tablename__ = 'wallet_incident_handover_dispositions'
    incident_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    generation: Mapped[int] = mapped_column(Integer, primary_key=True)
    handover_id: Mapped[str] = mapped_column(String(36), nullable=False)
    manifest_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    successor_scope: Mapped[str] = mapped_column(String(64), nullable=False)
    disposition: Mapped[str] = mapped_column(String(40), nullable=False)
    actor_id: Mapped[str] = mapped_column(String(36), nullable=False)
    reason_code: Mapped[str] = mapped_column(String(100), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


_MODELS = (WalletHandoverPreparation, WalletHandoverCommand, WalletIncidentHandoverDisposition)


def _immutable(*args, **kwargs):
    raise ValueError('wallet handover evidence is append-only')


for _model in _MODELS:
    event.listen(_model, 'before_update', _immutable)
    event.listen(_model, 'before_delete', _immutable)


@event.listens_for(Session, 'do_orm_execute')
def _reject_bulk_change(state):
    if state.is_update or state.is_delete:
        table = getattr(state.statement, 'table', None)
        if table is not None and table.name in {model.__tablename__ for model in _MODELS}:
            _immutable()
