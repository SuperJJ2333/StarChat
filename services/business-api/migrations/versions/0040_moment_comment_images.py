"""Store stable private image keys for Moments comments."""

from alembic import op
import sqlalchemy as sa


revision = "0040_moment_comment_images"
down_revision = "0039_merge_settings_wallet"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "moment_comments",
        sa.Column("image_object_keys", sa.JSON(), nullable=False, server_default="[]"),
    )


def downgrade() -> None:
    op.drop_column("moment_comments", "image_object_keys")
