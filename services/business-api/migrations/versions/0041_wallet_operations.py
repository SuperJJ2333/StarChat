"""Add internal daily-close evidence, incident lifecycle and Sandbox receipts.

Existing financial journals and wallet state are unchanged. Rollback preserves
operational evidence and disables the application features instead of deleting it.
"""
from alembic import op
import sqlalchemy as sa

revision = '0041_wallet_operations'
down_revision = '0040_wallet_safety'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table('wallet_daily_closes',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('day', sa.Date(), nullable=False),
        sa.Column('revision', sa.Integer(), nullable=False),
        sa.Column('previous_id', sa.String(36), nullable=True),
        sa.Column('digest', sa.String(64), nullable=False),
        sa.Column('report', sa.JSON(), nullable=False),
        sa.Column('created_by', sa.String(36), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('reason_code', sa.String(100), nullable=False),
        sa.Column('idempotency_key', sa.String(128), nullable=False),
        sa.ForeignKeyConstraint(['previous_id'], ['wallet_daily_closes.id']),
        sa.UniqueConstraint('day', 'revision', name='uq_wallet_close_day_revision'),
        sa.UniqueConstraint('idempotency_key', name='uq_wallet_close_idempotency'))
    op.create_table('wallet_incidents',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('fingerprint', sa.String(128), nullable=False),
        sa.Column('code', sa.String(100), nullable=False),
        sa.Column('severity', sa.String(2), nullable=False),
        sa.Column('subject_id', sa.String(128), nullable=False),
        sa.Column('status', sa.String(16), nullable=False),
        sa.Column('generation', sa.Integer(), nullable=False),
        sa.Column('version', sa.Integer(), nullable=False),
        sa.Column('condition_active', sa.Boolean(), nullable=False),
        sa.Column('opened_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('last_seen_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('cleared_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('acknowledged_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('resolved_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('acknowledged_by', sa.String(36), nullable=True),
        sa.Column('resolved_by', sa.String(36), nullable=True),
        sa.Column('clearance_digest', sa.String(64), nullable=True),
        sa.Column('last_escalation_slot', sa.Integer(), nullable=False),
        sa.UniqueConstraint('fingerprint', name='uq_wallet_incident_fingerprint'))
    op.create_table('wallet_incident_commands',
        sa.Column('idempotency_key', sa.String(128), primary_key=True),
        sa.Column('payload_digest', sa.String(64), nullable=False),
        sa.Column('result', sa.JSON(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False))
    op.create_table('wallet_alert_receipts',
        sa.Column('event_id', sa.String(36), primary_key=True),
        sa.Column('incident_id', sa.String(36), nullable=False),
        sa.Column('transport', sa.String(16), nullable=False),
        sa.Column('payload', sa.JSON(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False))
    op.create_table('wallet_monitor_heartbeats',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('last_attempt_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('last_success_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('last_error_code', sa.String(100), nullable=True))


def downgrade():
    raise RuntimeError('wallet operational evidence must be preserved; roll back application with operational commands disabled')
