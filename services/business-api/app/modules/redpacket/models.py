from datetime import datetime
from decimal import Decimal

from sqlalchemy import DateTime, ForeignKey, Numeric, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base

class RedPacket(Base):
    __tablename__ = "red_packets"
    __table_args__ = (UniqueConstraint("sender_id", "idempotency_key", name="uq_red_packet_create_idempotency"),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    sender_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    total: Mapped[Decimal] = mapped_column(Numeric(20,2), nullable=False)
    share_count: Mapped[int]
    mode: Mapped[str] = mapped_column(String(16), nullable=False)
    status: Mapped[str] = mapped_column(String(20), nullable=False)
    room_id: Mapped[str | None] = mapped_column(String(255))
    recipient_id: Mapped[str | None] = mapped_column(String(36))
    idempotency_key: Mapped[str] = mapped_column(String(128), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    shares: Mapped[list["RedPacketShare"]] = relationship(back_populates="packet", lazy="selectin", order_by="RedPacketShare.ordinal")

class RedPacketShare(Base):
    __tablename__ = "red_packet_shares"
    __table_args__ = (UniqueConstraint("packet_id", "ordinal", name="uq_red_packet_share_ordinal"), UniqueConstraint("packet_id", "claimed_by", name="uq_red_packet_claimant"))
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    packet_id: Mapped[str] = mapped_column(ForeignKey("red_packets.id"), nullable=False, index=True)
    ordinal: Mapped[int]
    amount: Mapped[Decimal] = mapped_column(Numeric(20,2), nullable=False)
    claimed_by: Mapped[str | None] = mapped_column(String(36))
    claimed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    packet: Mapped[RedPacket] = relationship(back_populates="shares")
