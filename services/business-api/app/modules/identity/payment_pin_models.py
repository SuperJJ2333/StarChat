"""Independent payment credentials and opaque single-use authorizations."""
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base


class PaymentPinCredential(Base):
    __tablename__ = 'payment_pin_credentials'

    user_id: Mapped[str] = mapped_column(ForeignKey('users.id'), primary_key=True)
    pin_hash: Mapped[str] = mapped_column(String(512), nullable=False)
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    failed_attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    locked_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    setup_key_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    setup_family_id: Mapped[str] = mapped_column(String(36), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class PaymentPinAuthorization(Base):
    __tablename__ = 'payment_pin_authorizations'

    token_hash: Mapped[str] = mapped_column(String(64), primary_key=True)
    user_id: Mapped[str] = mapped_column(ForeignKey('users.id'), nullable=False, index=True)
    family_id: Mapped[str] = mapped_column(String(36), nullable=False)
    credential_version: Mapped[int] = mapped_column(Integer, nullable=False)
    intent_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, index=True)
    consumed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
