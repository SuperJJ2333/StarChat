"""Add CAIBI red packets and preallocated shares."""
from alembic import op
import sqlalchemy as sa
revision = "0008_caibi_red_packets"
down_revision = "0007_caibi_ledger"
branch_labels = None
depends_on = None

def upgrade() -> None:
    op.create_table("red_packets", sa.Column("id", sa.String(36), primary_key=True), sa.Column("sender_id", sa.String(36), nullable=False), sa.Column("total", sa.Numeric(20,2), nullable=False), sa.Column("share_count", sa.Integer(), nullable=False), sa.Column("mode", sa.String(16), nullable=False), sa.Column("status", sa.String(20), nullable=False), sa.Column("room_id", sa.String(255)), sa.Column("recipient_id", sa.String(36)), sa.Column("idempotency_key", sa.String(128), nullable=False), sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False), sa.Column("created_at", sa.DateTime(timezone=True), nullable=False), sa.UniqueConstraint("sender_id", "idempotency_key", name="uq_red_packet_create_idempotency"))
    op.create_index("ix_red_packets_sender_id", "red_packets", ["sender_id"])
    op.create_table("red_packet_shares", sa.Column("id", sa.String(36), primary_key=True), sa.Column("packet_id", sa.String(36), sa.ForeignKey("red_packets.id"), nullable=False), sa.Column("ordinal", sa.Integer(), nullable=False), sa.Column("amount", sa.Numeric(20,2), nullable=False), sa.Column("claimed_by", sa.String(36)), sa.Column("claimed_at", sa.DateTime(timezone=True)), sa.UniqueConstraint("packet_id", "ordinal", name="uq_red_packet_share_ordinal"), sa.UniqueConstraint("packet_id", "claimed_by", name="uq_red_packet_claimant"))
    op.create_index("ix_red_packet_shares_packet_id", "red_packet_shares", ["packet_id"])

def downgrade() -> None:
    op.drop_index("ix_red_packet_shares_packet_id", table_name="red_packet_shares")
    op.drop_table("red_packet_shares")
    op.drop_index("ix_red_packets_sender_id", table_name="red_packets")
    op.drop_table("red_packets")
