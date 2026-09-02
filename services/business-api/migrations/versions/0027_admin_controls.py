"""Add admin command, ban and notice tables."""
from alembic import op
import sqlalchemy as sa

revision = "0027_admin_controls"
down_revision = "0026_moment_cover_media"
branch_labels = None
depends_on = None

def upgrade() -> None:
    op.create_table("admin_bans",
        sa.Column("id", sa.String(36), primary_key=True), sa.Column("subject_type", sa.String(16), nullable=False), sa.Column("subject_value", sa.String(255), nullable=False), sa.Column("reason_code", sa.String(100), nullable=False), sa.Column("starts_at", sa.DateTime(timezone=True), nullable=False), sa.Column("ends_at", sa.DateTime(timezone=True)), sa.Column("revoked_at", sa.DateTime(timezone=True)), sa.Column("created_by", sa.String(36), nullable=False), sa.Column("created_at", sa.DateTime(timezone=True), nullable=False), sa.UniqueConstraint("subject_type", "subject_value", name="uq_admin_ban_subject"))
    op.create_table("official_notices",
        sa.Column("id", sa.String(36), primary_key=True), sa.Column("title", sa.String(160), nullable=False), sa.Column("content", sa.Text(), nullable=False), sa.Column("audience", sa.String(40), nullable=False), sa.Column("status", sa.String(20), nullable=False), sa.Column("publish_at", sa.DateTime(timezone=True)), sa.Column("created_by", sa.String(36), nullable=False), sa.Column("idempotency_key", sa.String(128), nullable=False), sa.Column("created_at", sa.DateTime(timezone=True), nullable=False), sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False), sa.UniqueConstraint("created_by", "idempotency_key", name="uq_notice_idempotency"))
    op.create_table("admin_commands",
        sa.Column("id", sa.String(36), primary_key=True), sa.Column("scope", sa.String(100), nullable=False), sa.Column("idempotency_key", sa.String(128), nullable=False), sa.Column("request_hash", sa.String(64), nullable=False), sa.Column("result", sa.JSON(), nullable=False), sa.Column("created_at", sa.DateTime(timezone=True), nullable=False), sa.UniqueConstraint("scope", "idempotency_key", name="uq_admin_command_idempotency"))

def downgrade() -> None:
    op.drop_table("admin_commands"); op.drop_table("official_notices"); op.drop_table("admin_bans")
