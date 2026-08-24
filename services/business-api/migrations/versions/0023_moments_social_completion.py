"""Freeze tag sources for moment audiences."""
from alembic import op
import sqlalchemy as sa

revision = "0023_moments_social_completion"
down_revision = "0022_profile_nudge_suffix"
branch_labels = None
depends_on = None

def upgrade() -> None:
    op.add_column("moments", sa.Column("include_tag_ids", sa.JSON(), nullable=False, server_default="[]"))
    op.add_column("moments", sa.Column("exclude_tag_ids", sa.JSON(), nullable=False, server_default="[]"))

def downgrade() -> None:
    op.drop_column("moments", "exclude_tag_ids")
    op.drop_column("moments", "include_tag_ids")
