"""Append-only successful manual reserve publications."""
from datetime import datetime
from typing import Any

from sqlalchemy import JSON, BigInteger, CheckConstraint, DateTime, String, event
from sqlalchemy.orm import Mapped, Session, mapped_column

from app.core.database import Base


class ManualReserveEvaluation(Base):
    __tablename__ = 'ledger_manual_reserve_evaluations'
    __table_args__ = (
        CheckConstraint('observation_id > 0', name='ck_manual_reserve_observation'),
        CheckConstraint('expected_version IS NULL OR expected_version >= 1', name='ck_manual_reserve_expected'),
        CheckConstraint('result_version >= 1', name='ck_manual_reserve_result'),
        CheckConstraint('(expected_version IS NULL AND result_version = 1) OR '
                        '(expected_version IS NOT NULL AND result_version = expected_version + 1)',
                        name='ck_manual_reserve_version_step'),
    )
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    idempotency_key: Mapped[str] = mapped_column(String(128), nullable=False, unique=True)
    payload_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    source_identity: Mapped[str] = mapped_column(String(64), nullable=False)
    observation_id: Mapped[int] = mapped_column(BigInteger, nullable=False)
    cut_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    expected_version: Mapped[int | None] = mapped_column(BigInteger)
    result_version: Mapped[int] = mapped_column(BigInteger, nullable=False)
    evidence: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


def _reject_change(*_args, **_kwargs):
    raise ValueError('manual reserve evaluations are append-only')


event.listen(ManualReserveEvaluation, 'before_update', _reject_change)
event.listen(ManualReserveEvaluation, 'before_delete', _reject_change)


@event.listens_for(Session, 'do_orm_execute')
def _reject_bulk_change(execute_state):
    if execute_state.is_update or execute_state.is_delete:
        table = getattr(execute_state.statement, 'table', None)
        if table is not None and table.name == ManualReserveEvaluation.__tablename__:
            _reject_change()
