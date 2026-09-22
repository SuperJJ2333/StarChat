"""ADR-0077 实施补充: persistent case-to-finance-command binding.

One active binding per recharge request and per finance adjustment (flat
`state_active` discriminator: '1' for the single active BOUND row, '0' for
terminal rows). Expand-only; no ledger or existing table is touched.
"""
from alembic import op
import sqlalchemy as sa

revision = "0079_recharge_credit_bindings"
down_revision = "0078_phone_accounts"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "recharge_credit_bindings",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("request_id", sa.String(length=36),
            sa.ForeignKey("recharge_requests.id"), nullable=False, index=True),
        sa.Column("adjustment_id", sa.String(length=36), nullable=False, index=True),
        sa.Column("state", sa.String(length=16), nullable=False, server_default="BOUND"),
        sa.Column("state_active", sa.String(length=1), nullable=False, server_default="1"),
        sa.Column("bound_by", sa.String(length=36), nullable=False),
        sa.Column("failure_reason", sa.String(length=200), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("request_id", "state_active", name="uq_recharge_binding_active_request"),
        sa.UniqueConstraint("adjustment_id", "state_active", name="uq_recharge_binding_active_adjustment"),
    )


def downgrade():
    op.drop_table("recharge_credit_bindings")
