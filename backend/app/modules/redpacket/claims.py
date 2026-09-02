from datetime import datetime
from sqlalchemy import DateTime, ForeignKey, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column
from app.core.database import Base

class RedPacketClaim(Base):
    __tablename__ = "red_packet_claims"
    __table_args__ = (UniqueConstraint("packet_id", "user_id", name="uq_red_packet_claim_user"), UniqueConstraint("packet_id", "idempotency_key", name="uq_red_packet_claim_idempotency"))
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    packet_id: Mapped[str] = mapped_column(ForeignKey("red_packets.id"), nullable=False, index=True)
    share_id: Mapped[str] = mapped_column(ForeignKey("red_packet_shares.id"), nullable=False, unique=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    idempotency_key: Mapped[str] = mapped_column(String(128), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
