"""ADR-0077: final settlement columns on manual payout orders.

Expand-only. The original quote snapshot columns stay immutable; rate
adjustments append to `adjustment_history` and pin `final_rate`/
`final_receive`/`adjusted_digest`. Chain payment and settlement always use
`final_receive` when present.
"""
from alembic import op
import sqlalchemy as sa

revision = "0076_payout_settlement"
down_revision = "0075_business_groups"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("wallet_manual_payout_orders", sa.Column("final_rate", sa.Numeric(20, 6), nullable=True))
    op.add_column("wallet_manual_payout_orders", sa.Column("final_receive", sa.Numeric(30, 6), nullable=True))
    op.add_column("wallet_manual_payout_orders", sa.Column("adjusted_digest", sa.String(length=64), nullable=True))
    op.add_column("wallet_manual_payout_orders", sa.Column("adjustment_history", sa.JSON(), nullable=True))


def downgrade():
    op.drop_column("wallet_manual_payout_orders", "adjustment_history")
    op.drop_column("wallet_manual_payout_orders", "adjusted_digest")
    op.drop_column("wallet_manual_payout_orders", "final_receive")
    op.drop_column("wallet_manual_payout_orders", "final_rate")
