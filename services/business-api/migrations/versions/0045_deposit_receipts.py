"""Add per-log deposit obligations; never re-attribute legacy txid records."""
from alembic import op
import sqlalchemy as sa

revision = '0045_deposit_receipts'
down_revision = '0044_binding_policy'
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table('wallet_deposit_intents') as batch:
        batch.drop_constraint('ck_wallet_deposit_intent_status', type_='check')
        batch.create_check_constraint('ck_wallet_deposit_intent_status',
            "status IN ('OPEN', 'EXPIRED', 'CLOSED_BY_REBIND', 'FULFILLED')")
    op.create_table('wallet_deposit_receipts',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('network', sa.String(32), nullable=False),
        sa.Column('contract', sa.String(128), nullable=False),
        sa.Column('txid', sa.String(64), nullable=False),
        sa.Column('log_index', sa.Integer(), nullable=False),
        sa.Column('source_address', sa.String(34), nullable=False),
        sa.Column('official_address', sa.String(34), nullable=False),
        sa.Column('official_config_version', sa.String(128), nullable=False),
        sa.Column('amount_units', sa.String(100), nullable=False),
        sa.Column('amount', sa.Numeric(30, 6)),
        sa.Column('block_number', sa.BigInteger(), nullable=False),
        sa.Column('block_id', sa.String(64), nullable=False),
        sa.Column('block_time', sa.DateTime(timezone=True), nullable=False),
        sa.Column('evidence_policy', sa.String(64), nullable=False),
        sa.Column('evidence_source', sa.String(64), nullable=False),
        sa.Column('observed_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('facts_digest', sa.String(64), nullable=False),
        sa.Column('status', sa.String(16), nullable=False),
        sa.Column('reason_code', sa.String(100), nullable=False),
        sa.Column('pending_obligation', sa.Boolean(), nullable=False),
        sa.Column('intent_id', sa.String(36), sa.ForeignKey('wallet_deposit_intents.id')),
        sa.Column('user_id', sa.String(36)),
        sa.Column('ledger_transaction_id', sa.String(36), sa.ForeignKey('wallet_ledger_transactions.id')),
        sa.UniqueConstraint('network', 'contract', 'txid', 'log_index', name='uq_wallet_deposit_receipt_chain_event'),
        sa.UniqueConstraint('intent_id', name='uq_wallet_deposit_receipt_intent'),
        sa.CheckConstraint("status IN ('REVIEW', 'CREDITED')", name='ck_wallet_deposit_receipt_status'),
        sa.CheckConstraint('amount IS NULL OR amount >= 0', name='ck_wallet_deposit_receipt_amount'))
    op.create_table('wallet_deposit_receipt_anomalies',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('receipt_id', sa.String(36), sa.ForeignKey('wallet_deposit_receipts.id'), nullable=False),
        sa.Column('observed_digest', sa.String(64), nullable=False),
        sa.Column('reason_code', sa.String(100), nullable=False),
        sa.Column('observed_at', sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint('receipt_id', 'observed_digest', name='uq_wallet_deposit_receipt_anomaly'))
    if op.get_bind().dialect.name == 'postgresql':
        op.execute("""CREATE OR REPLACE FUNCTION wallet_deposit_intent_immutable() RETURNS trigger AS $$
        BEGIN
          IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'deposit intent history must be retained'; END IF;
          IF (to_jsonb(NEW) - ARRAY['status', 'closed_at'])
             IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['status', 'closed_at'])
             OR OLD.status <> 'OPEN'
             OR NEW.status NOT IN ('EXPIRED', 'CLOSED_BY_REBIND', 'FULFILLED')
             OR NEW.closed_at IS NULL
          THEN RAISE EXCEPTION 'immutable deposit intent'; END IF;
          RETURN NEW;
        END; $$ LANGUAGE plpgsql""")
        op.execute("""CREATE FUNCTION wallet_deposit_receipt_immutable() RETURNS trigger AS $$
        BEGIN
          IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'deposit receipt history must be retained'; END IF;
          IF (to_jsonb(NEW) - ARRAY['status','reason_code','pending_obligation','intent_id','user_id','ledger_transaction_id'])
             IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['status','reason_code','pending_obligation','intent_id','user_id','ledger_transaction_id'])
             OR OLD.status <> 'REVIEW'
             OR NOT ((NEW.status = 'REVIEW' AND
                       (NEW.pending_obligation,NEW.intent_id,NEW.user_id,NEW.ledger_transaction_id)
                       IS NOT DISTINCT FROM (OLD.pending_obligation,OLD.intent_id,OLD.user_id,OLD.ledger_transaction_id))
                     OR (NEW.status = 'CREDITED' AND NOT NEW.pending_obligation
                         AND NEW.intent_id IS NOT NULL AND NEW.ledger_transaction_id IS NOT NULL))
          THEN RAISE EXCEPTION 'immutable deposit receipt'; END IF;
          RETURN NEW;
        END; $$ LANGUAGE plpgsql""")
        op.execute("""CREATE TRIGGER wallet_deposit_receipt_immutable BEFORE UPDATE OR DELETE
        ON wallet_deposit_receipts FOR EACH ROW EXECUTE FUNCTION wallet_deposit_receipt_immutable()""")
        op.execute("""CREATE FUNCTION wallet_deposit_anomaly_immutable() RETURNS trigger AS $$
        BEGIN RAISE EXCEPTION 'deposit anomaly history must be retained'; END; $$ LANGUAGE plpgsql""")
        op.execute("""CREATE TRIGGER wallet_deposit_anomaly_immutable BEFORE UPDATE OR DELETE
        ON wallet_deposit_receipt_anomalies FOR EACH ROW EXECUTE FUNCTION wallet_deposit_anomaly_immutable()""")


def downgrade():
    raise RuntimeError('Deposit receipt history must be retained; use application rollback')
