"""Add metadata-only support queue tables."""
from alembic import op
import sqlalchemy as sa
revision = "0006_support_queue"
down_revision = "0005_audit_events"
branch_labels = None
depends_on = None

def upgrade() -> None:
    op.create_table("support_agent_presence", sa.Column("agent_id", sa.String(36), primary_key=True), sa.Column("online", sa.Boolean(), nullable=False), sa.Column("active_tickets", sa.Integer(), nullable=False), sa.Column("skills", sa.JSON(), nullable=False), sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False))
    op.create_table("support_tickets", sa.Column("id", sa.String(36), primary_key=True), sa.Column("user_id", sa.String(36), nullable=False), sa.Column("room_id", sa.String(255), nullable=False), sa.Column("skill", sa.String(80), nullable=False), sa.Column("status", sa.String(20), nullable=False), sa.Column("assignee_id", sa.String(36)), sa.Column("created_at", sa.DateTime(timezone=True), nullable=False), sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False))
    op.create_index("ix_support_tickets_user_id", "support_tickets", ["user_id"])
    op.create_index("ix_support_tickets_assignee_id", "support_tickets", ["assignee_id"])

def downgrade() -> None:
    op.drop_index("ix_support_tickets_assignee_id", table_name="support_tickets")
    op.drop_index("ix_support_tickets_user_id", table_name="support_tickets")
    op.drop_table("support_tickets")
    op.drop_table("support_agent_presence")
