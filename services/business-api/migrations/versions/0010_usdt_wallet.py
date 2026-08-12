"""Add USDT-TRC20 wallet state and isolated wallet ledger."""
from alembic import op
import sqlalchemy as sa
revision = "0010_usdt_wallet"
down_revision = "0009_red_packet_claims"
branch_labels = None
depends_on = None

def upgrade() -> None:
    op.create_table("wallet_ledger_transactions", sa.Column("id", sa.String(36), primary_key=True), sa.Column("asset", sa.String(20), nullable=False), sa.Column("scope", sa.String(80), nullable=False), sa.Column("idempotency_key", sa.String(128), nullable=False), sa.Column("actor_id", sa.String(36), nullable=False), sa.Column("reason_code", sa.String(100), nullable=False), sa.Column("created_at", sa.DateTime(timezone=True), nullable=False), sa.UniqueConstraint("scope", "idempotency_key", name="uq_wallet_ledger_idempotency"))
    op.create_table("wallet_ledger_entries", sa.Column("id", sa.String(36), primary_key=True), sa.Column("transaction_id", sa.String(36), sa.ForeignKey("wallet_ledger_transactions.id"), nullable=False), sa.Column("account_id", sa.String(64), nullable=False), sa.Column("asset", sa.String(20), nullable=False), sa.Column("amount", sa.Numeric(30,6), nullable=False), sa.Column("created_at", sa.DateTime(timezone=True), nullable=False))
    op.create_index("ix_wallet_ledger_entries_transaction_id", "wallet_ledger_entries", ["transaction_id"])
    op.create_index("ix_wallet_ledger_entries_account_id", "wallet_ledger_entries", ["account_id"])
    op.create_table("wallet_deposits", sa.Column("id", sa.String(36), primary_key=True), sa.Column("event_id", sa.String(128), nullable=False, unique=True), sa.Column("user_id", sa.String(36), nullable=False), sa.Column("txid", sa.String(128), nullable=False, unique=True), sa.Column("amount", sa.Numeric(30,6), nullable=False), sa.Column("confirmations", sa.Integer(), nullable=False), sa.Column("status", sa.String(20), nullable=False), sa.Column("created_at", sa.DateTime(timezone=True), nullable=False))
    op.create_index("ix_wallet_deposits_user_id", "wallet_deposits", ["user_id"])
    op.create_table("wallet_withdrawals", sa.Column("id", sa.String(36), primary_key=True), sa.Column("user_id", sa.String(36), nullable=False), sa.Column("client_order_id", sa.String(128), nullable=False), sa.Column("address", sa.String(128), nullable=False), sa.Column("amount", sa.Numeric(30,6), nullable=False), sa.Column("status", sa.String(32), nullable=False), sa.Column("finance_approver_id", sa.String(36)), sa.Column("admin_approver_id", sa.String(36)), sa.Column("provider_txid", sa.String(128)), sa.Column("created_at", sa.DateTime(timezone=True), nullable=False), sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False), sa.UniqueConstraint("user_id", "client_order_id", name="uq_wallet_withdrawal_order"))
    op.create_index("ix_wallet_withdrawals_user_id", "wallet_withdrawals", ["user_id"])
    op.create_table("wallet_controls", sa.Column("id", sa.String(20), primary_key=True), sa.Column("withdrawals_paused", sa.Boolean(), nullable=False), sa.Column("pause_reason", sa.String(255)))
    op.execute("""CREATE FUNCTION reject_wallet_ledger_mutation() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'wallet ledger is append-only'; END; $$ LANGUAGE plpgsql""")
    for table in ("wallet_ledger_transactions", "wallet_ledger_entries"):
        op.execute(f"CREATE TRIGGER {table}_append_only BEFORE UPDATE OR DELETE ON {table} FOR EACH ROW EXECUTE FUNCTION reject_wallet_ledger_mutation()")

def downgrade() -> None:
    for table in ("wallet_ledger_entries", "wallet_ledger_transactions"):
        op.execute(f"DROP TRIGGER IF EXISTS {table}_append_only ON {table}")
    op.execute("DROP FUNCTION IF EXISTS reject_wallet_ledger_mutation()")
    op.drop_table("wallet_controls")
    op.drop_index("ix_wallet_withdrawals_user_id", table_name="wallet_withdrawals")
    op.drop_table("wallet_withdrawals")
    op.drop_index("ix_wallet_deposits_user_id", table_name="wallet_deposits")
    op.drop_table("wallet_deposits")
    op.drop_index("ix_wallet_ledger_entries_account_id", table_name="wallet_ledger_entries")
    op.drop_index("ix_wallet_ledger_entries_transaction_id", table_name="wallet_ledger_entries")
    op.drop_table("wallet_ledger_entries")
    op.drop_table("wallet_ledger_transactions")
