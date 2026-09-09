"""Operational incident state, command replays and Sandbox delivery receipts."""
from datetime import datetime

from sqlalchemy import JSON, Boolean, DateTime, Integer, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base


class WalletIncident(Base):
    __tablename__ = 'wallet_incidents'
    __table_args__ = (UniqueConstraint('fingerprint', name='uq_wallet_incident_fingerprint'),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    fingerprint: Mapped[str] = mapped_column(String(128), nullable=False)
    code: Mapped[str] = mapped_column(String(100), nullable=False)
    severity: Mapped[str] = mapped_column(String(2), nullable=False)
    subject_id: Mapped[str] = mapped_column(String(128), nullable=False)
    status: Mapped[str] = mapped_column(String(16), nullable=False)
    generation: Mapped[int] = mapped_column(Integer, nullable=False)
    version: Mapped[int] = mapped_column(Integer, nullable=False)
    condition_active: Mapped[bool] = mapped_column(Boolean, nullable=False)
    opened_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    last_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    cleared_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    acknowledged_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    resolved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    acknowledged_by: Mapped[str | None] = mapped_column(String(36))
    resolved_by: Mapped[str | None] = mapped_column(String(36))
    clearance_digest: Mapped[str | None] = mapped_column(String(64))
    last_escalation_slot: Mapped[int] = mapped_column(Integer, nullable=False, default=0)


class WalletIncidentCommand(Base):
    __tablename__ = 'wallet_incident_commands'

    idempotency_key: Mapped[str] = mapped_column(String(128), primary_key=True)
    payload_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    result: Mapped[dict] = mapped_column(JSON, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class WalletAlertReceipt(Base):
    __tablename__ = 'wallet_alert_receipts'

    event_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    incident_id: Mapped[str] = mapped_column(String(36), nullable=False)
    transport: Mapped[str] = mapped_column(String(16), nullable=False)
    payload: Mapped[dict] = mapped_column(JSON, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
