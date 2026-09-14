"""Persist business-API owned support identity badges."""
from alembic import op
import sqlalchemy as sa

revision = "0065_support_profiles"
down_revision = "0064_admin_deposit_repairs"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "support_profiles",
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.id"), primary_key=True),
        sa.Column("badge", sa.String(6), nullable=False, server_default="官方客服"),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )


def downgrade() -> None:
    raise RuntimeError("Support profile data is retained; disable the feature instead of destructive downgrade")
