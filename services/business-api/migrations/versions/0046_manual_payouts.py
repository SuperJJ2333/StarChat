"""Add owner-operated manual payout history without changing legacy orders."""
from alembic import op
import sqlalchemy as sa

revision = '0046_manual_payouts'
down_revision = '0045_deposit_receipts'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table('wallet_manual_payout_quotes',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('user_id', sa.String(36), nullable=False),
        sa.Column('amount', sa.Numeric(30, 6), nullable=False),
        sa.Column('snapshot', sa.JSON(), nullable=False),
        sa.Column('digest', sa.String(64), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('expires_at', sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint('amount >= 10', name='ck_manual_quote_amount'),
        sa.CheckConstraint('expires_at > created_at', name='ck_manual_quote_expiry'))
    op.create_index('ix_wallet_manual_payout_quotes_user_id', 'wallet_manual_payout_quotes', ['user_id'])
    op.create_table('wallet_manual_payout_orders',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('quote_id', sa.String(36), sa.ForeignKey('wallet_manual_payout_quotes.id'), nullable=False, unique=True),
        sa.Column('user_id', sa.String(36), nullable=False),
        sa.Column('amount', sa.Numeric(30, 6), nullable=False),
        sa.Column('digest', sa.String(64), nullable=False),
        sa.Column('status', sa.String(16), nullable=False),
        sa.Column('claimed_by', sa.String(36)),
        sa.Column('claimed_at', sa.DateTime(timezone=True)),
        sa.Column('candidate_txid', sa.String(64)),
        sa.Column('review_reason', sa.String(80)),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("status IN ('REQUESTED','CLAIMED','UNKNOWN','SETTLED','CANCELLED')", name='ck_manual_payout_status'),
        sa.CheckConstraint('amount >= 10', name='ck_manual_payout_amount'),
        sa.CheckConstraint("(status IN ('REQUESTED','CANCELLED') AND claimed_by IS NULL AND claimed_at IS NULL AND candidate_txid IS NULL) OR (status IN ('CLAIMED','UNKNOWN','SETTLED') AND claimed_by IS NOT NULL AND claimed_at IS NOT NULL)", name='ck_manual_payout_claim'),
        sa.CheckConstraint("candidate_txid IS NULL OR status IN ('UNKNOWN','SETTLED')", name='ck_manual_payout_candidate'),
        sa.CheckConstraint("status != 'SETTLED' OR candidate_txid IS NOT NULL", name='ck_manual_payout_settled'))
    op.create_index('ix_wallet_manual_payout_orders_user_id', 'wallet_manual_payout_orders', ['user_id'])
    op.create_table('wallet_manual_payout_commands',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('actor_id', sa.String(36), nullable=False),
        sa.Column('operation', sa.String(24), nullable=False),
        sa.Column('idempotency_key', sa.String(128), nullable=False),
        sa.Column('digest', sa.String(64), nullable=False),
        sa.Column('response', sa.JSON(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint('actor_id', 'operation', 'idempotency_key', name='uq_manual_payout_command'))
    op.create_table('wallet_manual_payout_events',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('order_id', sa.String(36), sa.ForeignKey('wallet_manual_payout_orders.id'), nullable=False, unique=True),
        sa.Column('network', sa.String(32), nullable=False),
        sa.Column('contract', sa.String(34), nullable=False),
        sa.Column('txid', sa.String(64), nullable=False),
        sa.Column('log_index', sa.Integer(), nullable=False),
        sa.Column('evidence', sa.JSON(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint('network', 'contract', 'txid', 'log_index', name='uq_manual_payout_event'),
        sa.CheckConstraint('log_index >= 0', name='ck_manual_payout_log_index'))
    if op.get_bind().dialect.name == 'postgresql':
        op.execute("""CREATE FUNCTION wallet_manual_history_immutable() RETURNS trigger AS $$
        BEGIN RAISE EXCEPTION 'manual payout history must be retained'; END; $$ LANGUAGE plpgsql""")
        for table in ('quotes', 'commands', 'events'):
            op.execute(f"CREATE TRIGGER wallet_manual_{table}_immutable BEFORE UPDATE OR DELETE ON wallet_manual_payout_{table} FOR EACH ROW EXECUTE FUNCTION wallet_manual_history_immutable()")
        op.execute("""CREATE FUNCTION wallet_manual_order_guard() RETURNS trigger AS $$
        BEGIN
          IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'manual payout history must be retained'; END IF;
          IF OLD.status IN ('SETTLED','CANCELLED') AND to_jsonb(NEW) IS DISTINCT FROM to_jsonb(OLD)
             OR (NEW.id,NEW.quote_id,NEW.user_id,NEW.amount,NEW.digest,NEW.created_at)
                IS DISTINCT FROM (OLD.id,OLD.quote_id,OLD.user_id,OLD.amount,OLD.digest,OLD.created_at)
             OR (OLD.claimed_by IS NOT NULL AND NEW.claimed_by IS DISTINCT FROM OLD.claimed_by)
             OR (OLD.claimed_at IS NOT NULL AND NEW.claimed_at IS DISTINCT FROM OLD.claimed_at)
             OR (OLD.candidate_txid IS NOT NULL AND NEW.candidate_txid IS DISTINCT FROM OLD.candidate_txid)
          THEN RAISE EXCEPTION 'immutable manual payout order'; END IF;
          IF NEW.status <> OLD.status AND NOT (
            (OLD.status = 'REQUESTED' AND NEW.status IN ('CLAIMED','CANCELLED')) OR
            (OLD.status = 'CLAIMED' AND NEW.status IN ('UNKNOWN','SETTLED')) OR
            (OLD.status = 'UNKNOWN' AND NEW.status = 'SETTLED'))
          THEN RAISE EXCEPTION 'illegal manual payout transition'; END IF;
          RETURN NEW;
        END; $$ LANGUAGE plpgsql""")
        op.execute("CREATE TRIGGER wallet_manual_order_guard BEFORE UPDATE OR DELETE ON wallet_manual_payout_orders FOR EACH ROW EXECUTE FUNCTION wallet_manual_order_guard()")


def downgrade():
    raise RuntimeError('manual payout history must be retained; roll back application only')
