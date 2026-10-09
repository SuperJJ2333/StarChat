"""Expand durable notification continuity; no financial schema changes."""
from alembic import op
import sqlalchemy as sa

revision = '0095_wallet_source_alerts'
down_revision = '0094_support_finance_order_recovery'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table('wallet_source_alert_states',
        sa.Column('id', sa.String(20), primary_key=True),
        sa.Column('failed_since', sa.DateTime(timezone=True)),
        sa.Column('healthy_count', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('last_observation_id', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('notified_conditions', sa.JSON(), nullable=False, server_default='[]'),
        sa.Column('first_context', sa.JSON(), nullable=False, server_default='{}'),
        sa.Column('latest_context', sa.JSON(), nullable=False, server_default='{}'))


def downgrade():
    raise RuntimeError('Forward-only notification state; retain state when rolling back code')
