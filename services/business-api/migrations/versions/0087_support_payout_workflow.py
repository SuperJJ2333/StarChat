"""Durable support payout lease and execution boundary; historical policy unchanged."""
from alembic import op
import sqlalchemy as sa

revision='0087_support_payout_workflow'
down_revision='0086_support_order_notifications'
branch_labels=None
depends_on=None


def upgrade():
    op.create_table('wallet_support_payout_states',
        sa.Column('order_id',sa.String(36),sa.ForeignKey('wallet_manual_payout_orders.id'),primary_key=True),
        sa.Column('expires_at',sa.DateTime(timezone=True),nullable=False),
        sa.Column('claimed_by',sa.String(36)),
        sa.Column('claim_token',sa.String(64)),
        sa.Column('claim_expires_at',sa.DateTime(timezone=True)),
        sa.Column('execution_started_at',sa.DateTime(timezone=True)),
        sa.Column('review_authorized_at',sa.DateTime(timezone=True)),
        sa.Column('version',sa.Integer,nullable=False),
        sa.Column('review_required',sa.Boolean,nullable=False))
    op.create_index('ix_wallet_support_payout_states_expires_at','wallet_support_payout_states',['expires_at'])


def downgrade():
    raise RuntimeError('Preserve financial coordination state; use a forward migration')
