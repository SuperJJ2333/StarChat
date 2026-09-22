"""ADR-0078: group-owner commission snapshot columns on red_packets.

Expand-only. Every historical packet is backfilled to commission_status
'NONE' / fee_exempt false / rules_version 'rp-fee-v1' (pre-commission era);
no ledger row is rewritten.
"""
from alembic import op
import sqlalchemy as sa

revision = "0074_red_packet_commission"
down_revision = "0073_pricing_v2_reserve"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("red_packets", sa.Column("fee_exempt", sa.Boolean(), nullable=False, server_default=sa.false()))
    op.add_column("red_packets", sa.Column("fee_exempt_reason", sa.String(length=40), nullable=True))
    op.add_column("red_packets", sa.Column("group_joined_count", sa.Integer(), nullable=True))
    op.add_column("red_packets", sa.Column("commission_rate", sa.Numeric(10, 6), nullable=True))
    op.add_column("red_packets", sa.Column("commission_beneficiary_id", sa.String(length=36), nullable=True))
    op.add_column("red_packets", sa.Column("commission_status", sa.String(length=16), nullable=False, server_default="NONE"))
    op.add_column("red_packets", sa.Column("commission_amount", sa.Numeric(20, 2), nullable=True))
    op.add_column("red_packets", sa.Column("rules_version", sa.String(length=24), nullable=False, server_default="rp-fee-v1"))


def downgrade():
    op.drop_column("red_packets", "rules_version")
    op.drop_column("red_packets", "commission_amount")
    op.drop_column("red_packets", "commission_status")
    op.drop_column("red_packets", "commission_beneficiary_id")
    op.drop_column("red_packets", "commission_rate")
    op.drop_column("red_packets", "group_joined_count")
    op.drop_column("red_packets", "fee_exempt_reason")
    op.drop_column("red_packets", "fee_exempt")
