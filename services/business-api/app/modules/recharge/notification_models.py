"""Actor-local committed delivery order, separate from Outbox dispatch state."""
from datetime import datetime

from sqlalchemy import BigInteger, DateTime, ForeignKey, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base


class SupportOrderSubscription(Base):
    __tablename__ = 'support_order_subscriptions'

    actor_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    last_sequence: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)


class SupportOrderInbox(Base):
    __tablename__ = 'support_order_inbox'
    __table_args__ = (
        UniqueConstraint('actor_id', 'event_id', name='uq_support_order_inbox_event'),
        UniqueConstraint('actor_id', 'sequence', name='uq_support_order_inbox_sequence'),
    )

    cursor_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    actor_id: Mapped[str] = mapped_column(ForeignKey('support_order_subscriptions.actor_id'), nullable=False)
    event_id: Mapped[str] = mapped_column(String(36), nullable=False)
    sequence: Mapped[int] = mapped_column(BigInteger, nullable=False)
    kind: Mapped[str] = mapped_column(String(16), nullable=False)
    order_id: Mapped[str] = mapped_column(String(128), nullable=False)
    event_type: Mapped[str] = mapped_column(String(100), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
