"""Add immutable CAIBI ledger and adjustment workflow."""
from alembic import op
import sqlalchemy as sa
revision = "0007_caibi_ledger"
down_revision = "0006_support_queue"
branch_labels = None
depends_on = None

def upgrade() -> None:
    op.create_table("ledger_transactions", sa.Column("id", sa.String(36), primary_key=True), sa.Column("asset", sa.String(16), nullable=False), sa.Column("scope", sa.String(80), nullable=False), sa.Column("idempotency_key", sa.String(128), nullable=False), sa.Column("actor_id", sa.String(36), nullable=False), sa.Column("reason_code", sa.String(100), nullable=False), sa.Column("reversal_of_id", sa.String(36)), sa.Column("created_at", sa.DateTime(timezone=True), nullable=False), sa.UniqueConstraint("scope", "idempotency_key", name="uq_ledger_scope_idempotency"))
    op.create_table("ledger_entries", sa.Column("id", sa.String(36), primary_key=True), sa.Column("transaction_id", sa.String(36), sa.ForeignKey("ledger_transactions.id"), nullable=False), sa.Column("account_id", sa.String(64), nullable=False), sa.Column("asset", sa.String(16), nullable=False), sa.Column("amount", sa.Numeric(20, 2), nullable=False), sa.Column("created_at", sa.DateTime(timezone=True), nullable=False))
    op.create_index("ix_ledger_entries_transaction_id", "ledger_entries", ["transaction_id"])
    op.create_index("ix_ledger_entries_account_id", "ledger_entries", ["account_id"])
    op.create_table("adjustment_policies", sa.Column("actor_id", sa.String(36), primary_key=True), sa.Column("per_transaction", sa.Numeric(20,2), nullable=False), sa.Column("per_day", sa.Numeric(20,2), nullable=False), sa.Column("allowed_users", sa.JSON(), nullable=False), sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False))
    op.create_table("adjustment_requests", sa.Column("id", sa.String(36), primary_key=True), sa.Column("user_id", sa.String(36), nullable=False), sa.Column("amount", sa.Numeric(20,2), nullable=False), sa.Column("reason_code", sa.String(100), nullable=False), sa.Column("status", sa.String(30), nullable=False), sa.Column("submitted_by", sa.String(36), nullable=False), sa.Column("idempotency_key", sa.String(128), nullable=False), sa.Column("finance_reviewer_id", sa.String(36)), sa.Column("admin_reviewer_id", sa.String(36)), sa.Column("ledger_transaction_id", sa.String(36)), sa.Column("business_date", sa.Date(), nullable=False), sa.Column("created_at", sa.DateTime(timezone=True), nullable=False), sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False), sa.UniqueConstraint("submitted_by", "idempotency_key", name="uq_adjustment_submit_idempotency"))
    op.create_index("ix_adjustment_requests_user_id", "adjustment_requests", ["user_id"])
    op.create_index("ix_adjustment_requests_submitted_by", "adjustment_requests", ["submitted_by"])
    op.execute("""CREATE FUNCTION reject_ledger_mutation() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'ledger is append-only'; END; $$ LANGUAGE plpgsql""")
    for table in ("ledger_transactions", "ledger_entries"):
        op.execute(f"CREATE TRIGGER {table}_append_only BEFORE UPDATE OR DELETE ON {table} FOR EACH ROW EXECUTE FUNCTION reject_ledger_mutation()")

def downgrade() -> None:
    for table in ("ledger_entries", "ledger_transactions"):
        op.execute(f"DROP TRIGGER IF EXISTS {table}_append_only ON {table}")
    op.execute("DROP FUNCTION IF EXISTS reject_ledger_mutation()")
    op.drop_index("ix_adjustment_requests_submitted_by", table_name="adjustment_requests")
    op.drop_index("ix_adjustment_requests_user_id", table_name="adjustment_requests")
    op.drop_table("adjustment_requests")
    op.drop_table("adjustment_policies")
    op.drop_index("ix_ledger_entries_account_id", table_name="ledger_entries")
    op.drop_index("ix_ledger_entries_transaction_id", table_name="ledger_entries")
    op.drop_table("ledger_entries")
    op.drop_table("ledger_transactions")
