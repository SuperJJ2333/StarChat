from datetime import datetime
from typing import Any

from sqlalchemy import JSON, DateTime, String, event
from sqlalchemy.orm import Mapped, Session, mapped_column

from app.core.database import Base


class AuditEvent(Base):
    __tablename__ = "audit_events"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    actor_id: Mapped[str | None] = mapped_column(String(36), index=True)
    subject_type: Mapped[str] = mapped_column(String(100), nullable=False)
    subject_id: Mapped[str] = mapped_column(String(128), nullable=False, index=True)
    action: Mapped[str] = mapped_column(String(150), nullable=False, index=True)
    result: Mapped[str] = mapped_column(String(30), nullable=False)
    reason_code: Mapped[str] = mapped_column(String(100), nullable=False)
    trace_id: Mapped[str] = mapped_column(String(128), nullable=False, index=True)
    source_ip: Mapped[str | None] = mapped_column(String(64))
    source_device_id: Mapped[str | None] = mapped_column(String(36))
    before_data: Mapped[dict[str, Any] | None] = mapped_column(JSON)
    after_data: Mapped[dict[str, Any] | None] = mapped_column(JSON)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


def _reject_change(*_args, **_kwargs) -> None:
    raise ValueError("audit events are append-only")


event.listen(AuditEvent, "before_update", _reject_change)
event.listen(AuditEvent, "before_delete", _reject_change)


@event.listens_for(Session, "do_orm_execute")
def _reject_bulk_change(execute_state) -> None:
    if not (execute_state.is_update or execute_state.is_delete):
        return
    statement = execute_state.statement
    table = getattr(statement, "table", None)
    if table is not None and table.name == AuditEvent.__tablename__:
        _reject_change()
