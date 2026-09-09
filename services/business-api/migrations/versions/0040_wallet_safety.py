"""Add wallet conversion, local intent and opt-in reserve records.

No existing orders or journal entries are rewritten. Legacy holds require an
explicit reconstruction case before automated settlement can operate on them.
"""
from alembic import op
import sqlalchemy as sa

revision = '0040_wallet_safety'
down_revision = '0039_merge_settings_wallet'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table('wallet_conversions',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('user_id', sa.String(36), nullable=False),
        sa.Column('idempotency_key', sa.String(128), nullable=False),
        sa.Column('direction', sa.String(20), nullable=False),
        sa.Column('requested_amount', sa.Numeric(30, 6), nullable=False),
        sa.Column('source_amount', sa.Numeric(30, 6), nullable=False),
        sa.Column('target_amount', sa.Numeric(30, 6), nullable=False),
        sa.Column('status', sa.String(20), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint('user_id', 'idempotency_key', name='uq_wallet_conversion_intent'))
    op.create_index('ix_wallet_conversions_user_id', 'wallet_conversions', ['user_id'])
    op.create_table('wallet_payout_intents',
        sa.Column('withdrawal_id', sa.String(36), primary_key=True),
        sa.Column('digest', sa.String(64), nullable=False),
        sa.Column('epoch', sa.Integer(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False))
    op.create_table('wallet_withdrawal_authorizations',
        sa.Column('withdrawal_id', sa.String(36), primary_key=True),
        sa.Column('request_digest', sa.String(64), nullable=False))
    op.create_table('wallet_safety_states',
        sa.Column('id', sa.String(64), primary_key=True),
        sa.Column('restricted', sa.Boolean(), nullable=False),
        sa.Column('epoch', sa.Integer(), nullable=False),
        sa.Column('reason', sa.String(255), nullable=False))
    op.create_table('ledger_redeemability_reserve',
        sa.Column('id', sa.String(20), primary_key=True),
        sa.Column('eligible_usdt', sa.Numeric(30, 6), nullable=False),
        sa.Column('usdt_liability', sa.Numeric(30, 6), nullable=False),
        sa.Column('version', sa.Integer(), nullable=False),
        sa.Column('pending_payouts', sa.Integer(), nullable=False),
        sa.Column('outgoing_restricted', sa.Boolean(), nullable=False),
        sa.Column('observed_at', sa.DateTime(timezone=True), nullable=False))


def downgrade():
    # Financial history is never destroyed by a routine rollback.
    raise RuntimeError('wallet safety records must be preserved; roll back application with controls disabled')
