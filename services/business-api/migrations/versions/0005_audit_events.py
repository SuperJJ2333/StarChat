"""Add append-only audit events with database enforcement."""

from alembic import op
import sqlalchemy as sa

revision = "0005_audit_events"
down_revision = "0004_identity_foundation"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "audit_events",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("actor_id", sa.String(36)),
        sa.Column("subject_type", sa.String(100), nullable=False),
        sa.Column("subject_id", sa.String(128), nullable=False),
        sa.Column("action", sa.String(150), nullable=False),
        sa.Column("result", sa.String(30), nullable=False),
        sa.Column("reason_code", sa.String(100), nullable=False),
        sa.Column("trace_id", sa.String(128), nullable=False),
        sa.Column("source_ip", sa.String(64)),
        sa.Column("source_device_id", sa.String(36)),
        sa.Column("before_data", sa.JSON()),
        sa.Column("after_data", sa.JSON()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    for column in ("actor_id", "subject_id", "action", "trace_id"):
        op.create_index(f"ix_audit_events_{column}", "audit_events", [column])
    op.execute(
        """
        CREATE FUNCTION reject_audit_event_mutation() RETURNS trigger AS $$
        BEGIN
          RAISE EXCEPTION 'audit_events is append-only';
        END;
        $$ LANGUAGE plpgsql;
        """
    )
    op.execute(
        """
        CREATE TRIGGER audit_events_append_only
        BEFORE UPDATE OR DELETE ON audit_events
        FOR EACH ROW EXECUTE FUNCTION reject_audit_event_mutation();
        """
    )


def downgrade() -> None:
    op.execute("DROP TRIGGER IF EXISTS audit_events_append_only ON audit_events")
    op.execute("DROP FUNCTION IF EXISTS reject_audit_event_mutation()")
    for column in ("trace_id", "action", "subject_id", "actor_id"):
        op.drop_index(f"ix_audit_events_{column}", table_name="audit_events")
    op.drop_table("audit_events")
