"""Append-only review snapshots and completed wallet repair commands."""
from datetime import datetime
from sqlalchemy import BigInteger, Boolean, CheckConstraint, JSON, DateTime, ForeignKey, Integer, String, UniqueConstraint, event
from sqlalchemy.orm import Mapped, Session, mapped_column
from app.core.database import Base
# Register FK targets even when migration metadata imports only this module.
from app.modules.wallet import binding_models, funding_models, models, receipt_models  # noqa: F401


class RepairPreview(Base):
    __tablename__ = 'wallet_repair_previews'
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    actor_id: Mapped[str] = mapped_column(String(36), nullable=False)
    kind: Mapped[str] = mapped_column(String(24), nullable=False)
    digest: Mapped[str] = mapped_column(String(64), nullable=False)
    snapshot: Mapped[dict] = mapped_column(JSON, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class RepairCommand(Base):
    __tablename__ = 'wallet_repair_commands'
    __table_args__ = (UniqueConstraint('actor_id', 'idempotency_key', name='uq_wallet_repair_command_key'),
        UniqueConstraint('receipt_id', name='uq_wallet_repair_receipt'),
        UniqueConstraint('intent_id', name='uq_wallet_repair_intent'))
    operation_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    actor_id: Mapped[str] = mapped_column(String(36), nullable=False)
    idempotency_key: Mapped[str] = mapped_column(String(128), nullable=False)
    payload_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    preview_id: Mapped[str] = mapped_column(ForeignKey('wallet_repair_previews.id'), nullable=False)
    receipt_id: Mapped[str | None] = mapped_column(ForeignKey('wallet_deposit_receipts.id'))
    intent_id: Mapped[str | None] = mapped_column(ForeignKey('wallet_deposit_intents.id'))
    result: Mapped[dict] = mapped_column(JSON, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class ManualDepositCase(Base):
    __tablename__ = 'wallet_manual_deposit_cases'
    __table_args__ = (UniqueConstraint('actor_id', 'idempotency_key', name='uq_manual_deposit_case_key'),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    receipt_id: Mapped[str] = mapped_column(ForeignKey('wallet_deposit_receipts.id'), nullable=False)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    binding_id: Mapped[str] = mapped_column(ForeignKey('wallet_bindings.id'), nullable=False)
    binding_version: Mapped[int] = mapped_column(Integer, nullable=False)
    binding_effective_from_block: Mapped[int] = mapped_column(BigInteger, nullable=False)
    binding_effective_to_block: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    facts_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    actor_id: Mapped[str] = mapped_column(String(36), nullable=False)
    idempotency_key: Mapped[str] = mapped_column(String(128), nullable=False)
    payload_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    reason_detail_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    reason_detail: Mapped[str] = mapped_column(String(500), nullable=False)
    ownership_attestation: Mapped[bool] = mapped_column(Boolean, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class ManualDepositDecision(Base):
    __tablename__ = 'wallet_manual_deposit_decisions'
    __table_args__ = (UniqueConstraint('case_id', name='uq_manual_deposit_decision_case'),
        UniqueConstraint('actor_id', 'idempotency_key', name='uq_manual_deposit_decision_key'),
        CheckConstraint("decision IN ('APPROVED', 'REJECTED')", name='ck_manual_deposit_decision'))
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    case_id: Mapped[str] = mapped_column(ForeignKey('wallet_manual_deposit_cases.id'), nullable=False)
    actor_id: Mapped[str] = mapped_column(String(36), nullable=False)
    decision: Mapped[str] = mapped_column(String(16), nullable=False)
    idempotency_key: Mapped[str] = mapped_column(String(128), nullable=False)
    payload_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    reason_detail_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    reason_detail: Mapped[str] = mapped_column(String(500), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


def immutable(*args):
    raise ValueError('wallet repair records are append-only')


for model in (RepairPreview, RepairCommand, ManualDepositCase, ManualDepositDecision):
    event.listen(model, 'before_update', immutable)
    event.listen(model, 'before_delete', immutable)


@event.listens_for(Session, 'do_orm_execute')
def prevent_bulk_mutation(state):
    if state.is_update or state.is_delete:
        table = getattr(state.statement, 'table', None)
        if table is not None and table.name in {'wallet_repair_previews', 'wallet_repair_commands', 'wallet_manual_deposit_cases', 'wallet_manual_deposit_decisions'}:
            immutable()
