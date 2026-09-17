"""Red packet fee (ADR-0073): persist the 0.5% sender fee on each packet.

Expand-migrate-contract, non-destructive:
1. add the nullable `fee` column;
2. backfill every existing row with 0.00 (historical packets were fee-free);
3. tighten to NOT NULL with a 0.00 server default.
No ledger entry is rewritten; existing transactions stay append-only.
"""
from alembic import op
import sqlalchemy as sa

revision = '0068_red_packet_fee'
down_revision = '0067_wallet_owner_transfers'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        'red_packets',
        sa.Column('fee', sa.Numeric(20, 2), nullable=True),
    )
    op.execute("UPDATE red_packets SET fee = 0.00 WHERE fee IS NULL")
    op.alter_column(
        'red_packets',
        'fee',
        existing_type=sa.Numeric(20, 2),
        nullable=False,
        server_default=sa.text('0.00'),
    )


def downgrade():
    op.drop_column('red_packets', 'fee')
