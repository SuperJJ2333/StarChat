"""ADR-0076: reserve valuation columns (expand-only).

Adds the three-quantity snapshot fields to the redeemability reserve row:
caibi face amount, approved-unpaid USDT obligations (informational), the
valuation rate and the derived reference USDT value. Nullable throughout:
a missing fresh rate is recorded as NULL, never fabricated.
"""
from alembic import op
import sqlalchemy as sa

revision = "0073_pricing_v2_reserve"
down_revision = "0072_fx_rates"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("ledger_redeemability_reserve", sa.Column("caibi_face", sa.Numeric(30, 2), nullable=True))
    op.add_column("ledger_redeemability_reserve", sa.Column("approved_unpaid_usdt", sa.Numeric(30, 6), nullable=True))
    op.add_column("ledger_redeemability_reserve", sa.Column("valuation_rate", sa.Numeric(20, 6), nullable=True))
    op.add_column("ledger_redeemability_reserve", sa.Column("caibi_reference_usdt", sa.Numeric(30, 6), nullable=True))
    op.add_column("ledger_redeemability_reserve", sa.Column("valued_at", sa.DateTime(timezone=True), nullable=True))


def downgrade():
    op.drop_column("ledger_redeemability_reserve", "valued_at")
    op.drop_column("ledger_redeemability_reserve", "caibi_reference_usdt")
    op.drop_column("ledger_redeemability_reserve", "valuation_rate")
    op.drop_column("ledger_redeemability_reserve", "approved_unpaid_usdt")
    op.drop_column("ledger_redeemability_reserve", "caibi_face")
