"""Durable per-staff inbox; sequences are assigned only under recipient lock."""
from alembic import op
import sqlalchemy as sa

revision = '0086_support_order_notifications'
down_revision = '0085_support_staff_activation'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table('support_order_subscriptions',
        sa.Column('actor_id', sa.String(36), primary_key=True),
        sa.Column('last_sequence', sa.BigInteger(), nullable=False))
    op.create_table('support_order_inbox',
        sa.Column('cursor_id', sa.String(36), primary_key=True),
        sa.Column('actor_id', sa.String(36), sa.ForeignKey('support_order_subscriptions.actor_id'), nullable=False),
        sa.Column('event_id', sa.String(36), nullable=False),
        sa.Column('sequence', sa.BigInteger(), nullable=False),
        sa.Column('kind', sa.String(16), nullable=False),
        sa.Column('order_id', sa.String(128), nullable=False),
        sa.Column('event_type', sa.String(100), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint('actor_id', 'event_id', name='uq_support_order_inbox_event'),
        sa.UniqueConstraint('actor_id', 'sequence', name='uq_support_order_inbox_sequence'))
    op.create_index('ix_support_order_outbox_scan', 'outbox_events', ['topic', 'created_at', 'id'])


def downgrade():
    raise RuntimeError('Preserve support delivery history; use a forward migration')
