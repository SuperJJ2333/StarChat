"""Persist resumable funding discovery without modifying financial history."""
from alembic import op
import sqlalchemy as sa

revision = '0048_funding_scan'
down_revision = '0047_payout_candidates'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table('wallet_funding_scan_state',
        sa.Column('id', sa.String(20), primary_key=True),
        sa.Column('source_identity', sa.String(64), nullable=False),
        sa.Column('cursor_rowid', sa.BigInteger(), nullable=False),
        sa.Column('source_max_rowid', sa.BigInteger(), nullable=False),
        sa.Column('checkpoint_ms', sa.BigInteger(), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint('cursor_rowid >= 0 AND source_max_rowid >= cursor_rowid AND checkpoint_ms >= 0', name='ck_funding_scan_cursor'))
    op.create_table('wallet_funding_scan_items',
        sa.Column('txid', sa.String(64), primary_key=True),
        sa.Column('state', sa.String(16), nullable=False),
        sa.Column('discovered_rowid', sa.BigInteger(), nullable=False),
        sa.Column('attempts', sa.Integer(), nullable=False),
        sa.Column('last_reason', sa.String(80)),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("state IN ('PENDING','PROCESSED','RETRY')", name='ck_funding_scan_item_state'),
        sa.CheckConstraint('discovered_rowid > 0 AND attempts >= 0', name='ck_funding_scan_item_progress'))


def downgrade():
    raise RuntimeError('funding scan progress must be retained; roll back application only')
