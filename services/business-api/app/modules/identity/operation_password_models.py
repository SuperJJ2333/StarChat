"""Administrator-only credential, durable failure window, and setup replay."""
from datetime import datetime
from sqlalchemy import DateTime, Integer, JSON, String, Text, UniqueConstraint, CheckConstraint, event
from sqlalchemy.orm import Mapped, mapped_column, Session
from app.core.database import Base


class AdminOperationCredential(Base):
    __tablename__ = 'identity_admin_operation_credentials'
    __table_args__ = (CheckConstraint('version > 0',name='ck_admin_operation_version'),)
    user_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    password_hash: Mapped[str] = mapped_column(Text, nullable=False)
    version: Mapped[int] = mapped_column(Integer, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class AdminOperationAttempt(Base):
    __tablename__ = 'identity_admin_operation_attempts'
    __table_args__ = (CheckConstraint('failed_count >= 0',name='ck_admin_operation_failed_count'),)
    user_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    failed_count: Mapped[int] = mapped_column(Integer, nullable=False)
    window_started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    locked_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class AdminOperationCommand(Base):
    __tablename__ = 'identity_admin_operation_commands'
    __table_args__ = (UniqueConstraint('actor_id','idempotency_key',name='uq_admin_operation_actor_key'),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    actor_id: Mapped[str] = mapped_column(String(36), nullable=False)
    idempotency_key: Mapped[str] = mapped_column(String(128), nullable=False)
    request_hash: Mapped[str] = mapped_column(Text, nullable=False)
    credential_version: Mapped[int] = mapped_column(Integer, nullable=False)
    result: Mapped[dict] = mapped_column(JSON, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


def _immutable(*args,**kwargs):
    raise ValueError('admin operation commands are append-only')


event.listen(AdminOperationCommand,'before_update',_immutable)
event.listen(AdminOperationCommand,'before_delete',_immutable)


@event.listens_for(Session,'do_orm_execute')
def _reject_bulk_change(execute_state):
    if execute_state.is_update or execute_state.is_delete:
        table=getattr(execute_state.statement,'table',None)
        if table is not None and table.name==AdminOperationCommand.__tablename__: _immutable()
