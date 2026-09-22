"""ADR-0079: business group registry (owner authority + transfer tenure).

Expand-only. `owner_since` NULL means "tenure cannot be proven" (legacy
groups discovered passively); only audited paths may set it.
"""
from alembic import op
import sqlalchemy as sa

revision = "0075_business_groups"
down_revision = "0074_red_packet_commission"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "business_groups",
        sa.Column("room_id", sa.String(length=255), primary_key=True),
        sa.Column("owner_user_id", sa.String(length=36), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("owner_since", sa.DateTime(timezone=True), nullable=True),
        sa.Column("tenure_source", sa.String(length=24), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )


def downgrade():
    op.drop_table("business_groups")
