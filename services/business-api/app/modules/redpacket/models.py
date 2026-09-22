from datetime import datetime
from decimal import Decimal

from sqlalchemy import DateTime, ForeignKey, Numeric, String, UniqueConstraint, text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base

class RedPacket(Base):
    __tablename__ = "red_packets"
    __table_args__ = (UniqueConstraint("sender_id", "idempotency_key", name="uq_red_packet_create_idempotency"),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    sender_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    total: Mapped[Decimal] = mapped_column(Numeric(20,2), nullable=False)
    # ADR-0073：创建时向发送方收取的手续费（0.5%，最低 0.01），随单据持久化，
    # 使退款/对账不必按当前费率重算。历史红包为 0.00（当时免费）。
    fee: Mapped[Decimal] = mapped_column(
        Numeric(20,2), nullable=False, server_default=text("0.00"), default=Decimal("0.00")
    )
    share_count: Mapped[int]
    mode: Mapped[str] = mapped_column(String(16), nullable=False)
    status: Mapped[str] = mapped_column(String(20), nullable=False)
    room_id: Mapped[str | None] = mapped_column(String(255))
    recipient_id: Mapped[str | None] = mapped_column(String(36))
    idempotency_key: Mapped[str] = mapped_column(String(128), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    # ADR-0078：群主抽成与免手续费快照（创建期锁定，转让不改受益人）。
    fee_exempt: Mapped[bool] = mapped_column(nullable=False, default=False, server_default=text("0"))
    fee_exempt_reason: Mapped[str | None] = mapped_column(String(40), nullable=True)
    group_joined_count: Mapped[int | None] = mapped_column(nullable=True)
    commission_rate: Mapped[Decimal | None] = mapped_column(Numeric(10, 6), nullable=True)
    commission_beneficiary_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    commission_status: Mapped[str] = mapped_column(String(16), nullable=False, default="NONE", server_default=text("'NONE'"))
    commission_amount: Mapped[Decimal | None] = mapped_column(Numeric(20, 2), nullable=True)
    rules_version: Mapped[str] = mapped_column(String(24), nullable=False, default="rp-fee-v1", server_default=text("'rp-fee-v1'"))
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
