"""Persist idempotent Matrix profile synchronization state."""

from alembic import op
import sqlalchemy as sa


revision = "0019_matrix_profile_sync"
down_revision = "0018_avatar_uploads"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "users", sa.Column("matrix_avatar_source_key", sa.String(512), nullable=True)
    )
    op.add_column(
        "users", sa.Column("matrix_avatar_mxc_uri", sa.String(512), nullable=True)
    )
    op.add_column(
        "users",
        sa.Column("matrix_profile_synced_at", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("users", "matrix_profile_synced_at")
    op.drop_column("users", "matrix_avatar_mxc_uri")
    op.drop_column("users", "matrix_avatar_source_key")
