"""Store moment covers by stable private object key."""

from alembic import op
import sqlalchemy as sa


revision = "0026_moment_cover_media"
down_revision = "0025_moment_drafts_native_ads"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "moment_media_uploads",
        sa.Column(
            "purpose",
            sa.String(30),
            nullable=False,
            server_default="MOMENT_IMAGE",
        ),
    )
    op.add_column(
        "moments_preferences",
        sa.Column("cover_object_key", sa.String(512), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("moments_preferences", "cover_object_key")
    op.drop_column("moment_media_uploads", "purpose")
