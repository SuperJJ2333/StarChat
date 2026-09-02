"""Add chat transfers with escrow state machine."""
from alembic import op
import sqlalchemy as sa

revision = "0029_chat_transfers"
down_revision = "0028_notice_receipts_ads"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "chat_transfers",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("sender_id", sa.String(36), nullable=False),
        sa.Column("receiver_id", sa.String(36), nullable=False),
        sa.Column("amount", sa.Numeric(20, 2), nullable=False),
        sa.Column("fee", sa.Numeric(20, 2), nullable=False),
        sa.Column("note", sa.String(64)),
        sa.Column("room_id", sa.String(255)),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("idempotency_key", sa.String(128), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("sender_id", "idempotency_key", name="uq_chat_transfer_create_idempotency"),
    )
    op.create_index("ix_chat_transfers_sender_id", "chat_transfers", ["sender_id"])
    op.create_index("ix_chat_transfers_receiver_id", "chat_transfers", ["receiver_id"])
    op.create_index("ix_chat_transfers_status_expires_at", "chat_transfers", ["status", "expires_at"])


def downgrade() -> None:
    op.drop_index("ix_chat_transfers_status_expires_at", table_name="chat_transfers")
    op.drop_index("ix_chat_transfers_receiver_id", table_name="chat_transfers")
    op.drop_index("ix_chat_transfers_sender_id", table_name="chat_transfers")
    op.drop_table("chat_transfers")
