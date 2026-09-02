"""Add durable private avatar upload sessions."""

from alembic import op
import sqlalchemy as sa


revision = "0018_avatar_uploads"
down_revision = "0017_registration_profile"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "avatar_uploads",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column(
            "owner_id",
            sa.String(36),
            sa.ForeignKey("users.id"),
            nullable=False,
        ),
        sa.Column("mime_type", sa.String(100), nullable=False),
        sa.Column("byte_size", sa.Integer(), nullable=False),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("object_key", sa.String(512), nullable=False, unique=True),
        sa.Column("content_hash", sa.String(64), nullable=True),
        sa.Column("idempotency_key", sa.String(128), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("cancelled_at", sa.DateTime(timezone=True), nullable=True),
        sa.UniqueConstraint(
            "owner_id",
            "idempotency_key",
            name="uq_avatar_upload_owner_idempotency",
        ),
    )
    op.create_index("ix_avatar_uploads_owner_id", "avatar_uploads", ["owner_id"])
    op.create_index("ix_avatar_uploads_status", "avatar_uploads", ["status"])


def downgrade() -> None:
    op.drop_index("ix_avatar_uploads_status", table_name="avatar_uploads")
    op.drop_index("ix_avatar_uploads_owner_id", table_name="avatar_uploads")
    op.drop_table("avatar_uploads")
