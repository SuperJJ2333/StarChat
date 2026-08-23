"""Store the user-visible nudge suffix in the profile."""
from alembic import op
import sqlalchemy as sa

revision = "0022_profile_nudge_suffix"
down_revision = "0021_group_auto_join"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("users", sa.Column("nudge_suffix", sa.String(length=32), nullable=True))


def downgrade() -> None:
    op.drop_column("users", "nudge_suffix")
