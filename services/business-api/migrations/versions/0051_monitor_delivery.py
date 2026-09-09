"""Persist the worker's external alert delivery configuration in its heartbeat."""
from alembic import op
import sqlalchemy as sa

revision = '0051_monitor_delivery'
down_revision = '0050_manual_reserve'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('wallet_monitor_heartbeats', sa.Column(
        'external_delivery_configured', sa.Boolean(), nullable=False,
        server_default=sa.false()))


def downgrade():
    raise RuntimeError('monitor delivery state must be retained; roll back application only')
