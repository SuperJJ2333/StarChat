"""Append corrected evidence locators, retaining original payout history."""
from alembic import op
import sqlalchemy as sa

revision = '0047_payout_candidates'
down_revision = '0046_manual_payouts'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table('wallet_manual_payout_candidates',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('order_id', sa.String(36), sa.ForeignKey('wallet_manual_payout_orders.id'), nullable=False),
        sa.Column('txid', sa.String(64), nullable=False),
        sa.Column('actor_id', sa.String(36), nullable=False),
        sa.Column('reason_code', sa.String(80), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint('order_id', 'txid', name='uq_manual_payout_candidate'))
    if op.get_bind().dialect.name == 'postgresql':
        op.execute("CREATE TRIGGER wallet_manual_candidates_immutable BEFORE UPDATE OR DELETE ON wallet_manual_payout_candidates FOR EACH ROW EXECUTE FUNCTION wallet_manual_history_immutable()")


def downgrade():
    raise RuntimeError('manual payout candidate history must be retained; roll back application only')
