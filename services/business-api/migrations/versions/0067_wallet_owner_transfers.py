"""Immutable declarations of owner-initiated manual-wallet outflows (ADR-0071)."""
from alembic import op
import sqlalchemy as sa

revision = '0067_wallet_owner_transfers'
down_revision = '0066_manual_deposit_cases'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table('wallet_manual_owner_transfers',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('txid', sa.String(64), nullable=False),
        sa.Column('log_index', sa.BigInteger(), nullable=False),
        sa.Column('to_address', sa.String(34), nullable=False),
        sa.Column('amount', sa.Numeric(30, 6), nullable=False),
        sa.Column('amount_units', sa.String(100), nullable=False),
        sa.Column('reason_code', sa.String(100), nullable=False),
        sa.Column('reason_detail', sa.String(500), nullable=False),
        sa.Column('declared_by', sa.String(36), nullable=False),
        sa.Column('digest', sa.String(64), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint('txid', 'log_index', name='uq_wallet_owner_transfer_log'),
        sa.UniqueConstraint('digest', name='uq_wallet_owner_transfer_digest'))
    op.create_index('ix_wallet_manual_owner_transfers_txid', 'wallet_manual_owner_transfers', ['txid'])
    if op.get_bind().dialect.name == 'postgresql':
        op.execute("CREATE TRIGGER wallet_manual_owner_transfers_immutable BEFORE UPDATE OR DELETE ON "
                   "wallet_manual_owner_transfers FOR EACH ROW EXECUTE FUNCTION wallet_repair_immutable()")


def downgrade():
    raise RuntimeError('retain owner transfer declarations; use application rollback')
