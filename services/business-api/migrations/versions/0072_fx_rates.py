"""ADR-0076: persistent USD/CNY reference-rate cache (60-minute TTL).

Expand-only: one row per currency pair. `rate` stays nullable because the
claim protocol inserts a placeholder row before the first successful fetch.
No existing table or ledger data is touched.
"""
from alembic import op
import sqlalchemy as sa

revision = "0072_fx_rates"
down_revision = "0071_direct_room_generations"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "fx_rates",
        sa.Column("pair", sa.String(length=16), primary_key=True),
        sa.Column("rate", sa.Numeric(20, 6), nullable=True),
        sa.Column("fetched_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("upstream_uptime", sa.String(length=64), nullable=True),
        sa.Column("last_attempt_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_error_code", sa.String(length=64), nullable=True),
        sa.Column("fetch_state", sa.String(length=16), nullable=False, server_default="idle"),
        sa.Column("fetch_claimed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("fetch_claimed_by", sa.String(length=64), nullable=True),
    )


def downgrade():
    op.drop_table("fx_rates")
