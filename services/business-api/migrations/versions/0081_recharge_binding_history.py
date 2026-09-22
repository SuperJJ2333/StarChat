"""Preserve recharge binding history and approved settlement inputs."""
from alembic import op
import sqlalchemy as sa

revision = "0081_recharge_binding_history"
down_revision = "0080_group_transfer_intents"
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table("recharge_credit_bindings") as batch:
        batch.alter_column("state_active", existing_type=sa.String(1), nullable=True)
        batch.add_column(sa.Column("final_rate", sa.Numeric(20, 6), nullable=True))
        batch.add_column(sa.Column("final_caibi_amount", sa.Numeric(20, 2), nullable=True))
    op.execute("UPDATE recharge_credit_bindings SET state_active = NULL WHERE state_active = '0'")


def downgrade():
    raise RuntimeError("Binding history is append-only; restore via a forward migration")
