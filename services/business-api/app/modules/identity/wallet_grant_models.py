"""Server-side wallet access state; no bearer token or credential secrets."""
from datetime import datetime
from sqlalchemy import DateTime, String, CheckConstraint, Integer
from sqlalchemy.orm import Mapped, mapped_column
from app.core.database import Base


class WalletAccessGrant(Base):
    __tablename__ = 'identity_wallet_access_grants'
    __table_args__ = (CheckConstraint('expires_at > verified_at', name='ck_wallet_grant_deadline'),)
    family_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    grant_id: Mapped[str] = mapped_column(String(36), nullable=False, unique=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    device_id: Mapped[str] = mapped_column(String(36), nullable=False)
    scope: Mapped[str] = mapped_column(String(32), nullable=False)
    auth_mode: Mapped[str] = mapped_column(String(32), nullable=False)
    configuration_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    credential_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    verified_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class WalletAccessAttempt(Base):
    __tablename__ = 'identity_wallet_access_attempts'
    user_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    attempt_count: Mapped[int] = mapped_column(Integer, nullable=False)
    window_started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
