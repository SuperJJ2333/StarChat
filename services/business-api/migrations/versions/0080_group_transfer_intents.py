"""ADR-0079 实施补充: durable group-owner transfer operation intents.

Each transfer is a persistent, resumable operation (stage machine over the
Matrix power-level application), never a single-transaction claim of
success. Expand-only.
"""
from alembic import op
import sqlalchemy as sa

revision = "0080_group_transfer_intents"
down_revision = "0079_recharge_credit_bindings"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "group_transfer_intents",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("room_id", sa.String(length=255), nullable=False, index=True),
        sa.Column("requester_user_id", sa.String(length=36), nullable=False),
        sa.Column("expected_old_owner_user_id", sa.String(length=36), nullable=False),
        sa.Column("new_owner_user_id", sa.String(length=36), nullable=False),
        sa.Column("request_digest", sa.String(length=64), nullable=False),
        sa.Column("idempotency_key", sa.String(length=128), nullable=False),
        sa.Column("stage", sa.String(length=20), nullable=False, server_default="VALIDATED", index=True),
        sa.Column("attempts", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("claim_token", sa.String(length=64), nullable=True),
        sa.Column("claim_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_error_code", sa.String(length=64), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.UniqueConstraint("idempotency_key", name="uq_group_transfer_idempotency"),
    )


def downgrade():
    op.drop_table("group_transfer_intents")
