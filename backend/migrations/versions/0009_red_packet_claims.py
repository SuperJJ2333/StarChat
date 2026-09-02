"""Reserve red packet claims to make concurrent user claims unique."""
from alembic import op
import sqlalchemy as sa
revision = "0009_red_packet_claims"
down_revision = "0008_caibi_red_packets"
branch_labels = None
depends_on = None

def upgrade() -> None:
    op.create_table("red_packet_claims", sa.Column("id", sa.String(36), primary_key=True), sa.Column("packet_id", sa.String(36), sa.ForeignKey("red_packets.id"), nullable=False), sa.Column("share_id", sa.String(36), sa.ForeignKey("red_packet_shares.id"), nullable=False, unique=True), sa.Column("user_id", sa.String(36), nullable=False), sa.Column("idempotency_key", sa.String(128), nullable=False), sa.Column("created_at", sa.DateTime(timezone=True), nullable=False), sa.UniqueConstraint("packet_id", "user_id", name="uq_red_packet_claim_user"), sa.UniqueConstraint("packet_id", "idempotency_key", name="uq_red_packet_claim_idempotency"))
    op.create_index("ix_red_packet_claims_packet_id", "red_packet_claims", ["packet_id"])

def downgrade() -> None:
    op.drop_index("ix_red_packet_claims_packet_id", table_name="red_packet_claims")
    op.drop_table("red_packet_claims")
