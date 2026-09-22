"""ADR-0077: manual recharge requests and the official CS directory.

Expand-only. `evidence_txid` is globally unique so one on-chain payment
evidence can never fund two recharge requests. Requests never touch
balances; crediting happens through the existing public finance services.
"""
from alembic import op
import sqlalchemy as sa

revision = "0077_recharge_requests"
down_revision = "0076_payout_settlement"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "recharge_requests",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("user_id", sa.String(length=36), sa.ForeignKey("users.id"), nullable=False, index=True),
        sa.Column("amount_usdt", sa.Numeric(30, 6), nullable=False),
        sa.Column("evidence_txid", sa.String(length=64), nullable=True),
        sa.Column("note", sa.String(length=200), nullable=True),
        sa.Column("status", sa.String(length=16), nullable=False, server_default="SUBMITTED", index=True),
        sa.Column("fx_rate", sa.Numeric(20, 6), nullable=True),
        sa.Column("fx_rate_stale", sa.Boolean(), nullable=True),
        sa.Column("decided_by", sa.String(length=36), nullable=True),
        sa.Column("decided_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("decision_reason", sa.String(length=200), nullable=True),
        sa.Column("final_rate", sa.Numeric(20, 6), nullable=True),
        sa.Column("final_caibi_amount", sa.Numeric(20, 2), nullable=True),
        sa.Column("ledger_transaction_id", sa.String(length=36), nullable=True),
        sa.Column("adjustment_id", sa.String(length=36), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("evidence_txid", name="uq_recharge_evidence"),
    )
    op.create_table(
        "cs_directory_entries",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("cs_user_id", sa.String(length=36), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("display_name", sa.String(length=64), nullable=False),
        sa.Column("payment_address", sa.String(length=128), nullable=False),
        sa.Column("note", sa.String(length=200), nullable=True),
        sa.Column("enabled", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("sort", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )


def downgrade():
    op.drop_table("cs_directory_entries")
    op.drop_table("recharge_requests")
