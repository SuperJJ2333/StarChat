"""Expand support order ownership and receipt settlement links; preserve history."""
from alembic import op
import sqlalchemy as sa
revision='0084_support_order_workflow'
down_revision='0083_phone_wallet_refresh_merge'
branch_labels=None
depends_on=None


def upgrade():
    for column in [
        sa.Column('expires_at',sa.DateTime(timezone=True)),
        sa.Column('processing_stage',sa.String(32)),
        sa.Column('official_payment',sa.JSON()),
        sa.Column('claimed_by',sa.String(36)),
        sa.Column('claim_token_hash',sa.String(64)),
        sa.Column('claim_expires_at',sa.DateTime(timezone=True)),
        sa.Column('receipt_id',sa.String(36)),
        sa.Column('actual_received_usdt',sa.Numeric(30,6)),
        sa.Column('payment_verified_at',sa.DateTime(timezone=True)),
        sa.Column('review_authorized_at',sa.DateTime(timezone=True)),
    ]: op.add_column('recharge_requests',column)
    op.create_index('uq_recharge_request_receipt','recharge_requests',['receipt_id'],unique=True)
    op.create_table('wallet_recharge_receipt_reservations',
        sa.Column('receipt_id',sa.String(36),sa.ForeignKey('wallet_deposit_receipts.id'),primary_key=True),
        sa.Column('request_id',sa.String(36),nullable=False),
        sa.Column('user_id',sa.String(36),nullable=False),
        sa.Column('state',sa.String(16),nullable=False),
        sa.Column('facts_digest',sa.String(64),nullable=False),
        sa.Column('verified_at',sa.DateTime(timezone=True),nullable=False),
        sa.Column('created_at',sa.DateTime(timezone=True),nullable=False),
        sa.Column('ledger_transaction_id',sa.String(36)),
        sa.UniqueConstraint('request_id',name='uq_recharge_receipt_request'),
        sa.UniqueConstraint('ledger_transaction_id',name='uq_recharge_receipt_ledger'))
    op.add_column('wallet_deposit_receipts',sa.Column('recharge_request_id',sa.String(36)))
    op.add_column('wallet_deposit_receipts',sa.Column('caibi_ledger_transaction_id',sa.String(36)))
    op.create_index('uq_receipt_recharge_request','wallet_deposit_receipts',['recharge_request_id'],unique=True)
    op.create_index('uq_receipt_caibi_ledger','wallet_deposit_receipts',['caibi_ledger_transaction_id'],unique=True)
    if op.get_bind().dialect.name=='postgresql':
        op.execute("""CREATE FUNCTION wallet_recharge_reservation_immutable() RETURNS trigger AS $$
        BEGIN
          IF TG_OP='DELETE' THEN RAISE EXCEPTION 'immutable support receipt reservation history'; END IF;
          IF OLD.state<>'RESERVED' OR
            (to_jsonb(NEW)-ARRAY['verified_at','state','ledger_transaction_id']) IS DISTINCT FROM
            (to_jsonb(OLD)-ARRAY['verified_at','state','ledger_transaction_id']) THEN
            RAISE EXCEPTION 'immutable support receipt reservation identity';
          END IF;
          IF NEW.state='RESERVED' AND NEW.ledger_transaction_id IS NULL THEN RETURN NEW; END IF;
          IF NEW.state='CONSUMED' AND NEW.ledger_transaction_id IS NOT NULL AND
             NEW.verified_at IS NOT DISTINCT FROM OLD.verified_at THEN RETURN NEW; END IF;
          RAISE EXCEPTION 'immutable support receipt reservation lifecycle';
        END; $$ LANGUAGE plpgsql""")
        op.execute("""CREATE TRIGGER wallet_recharge_reservation_guard
          BEFORE UPDATE OR DELETE ON wallet_recharge_receipt_reservations
          FOR EACH ROW EXECUTE FUNCTION wallet_recharge_reservation_immutable()""")
        op.execute("""CREATE OR REPLACE FUNCTION wallet_deposit_receipt_immutable() RETURNS trigger AS $$
        BEGIN
          IF TG_OP='DELETE' THEN RAISE EXCEPTION 'deposit receipt history must be retained'; END IF;
          IF (to_jsonb(NEW) - ARRAY['status','reason_code','pending_obligation','intent_id','manual_case_id','user_id','ledger_transaction_id','recharge_request_id','caibi_ledger_transaction_id']) IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['status','reason_code','pending_obligation','intent_id','manual_case_id','user_id','ledger_transaction_id','recharge_request_id','caibi_ledger_transaction_id']) OR OLD.status<>'REVIEW' THEN RAISE EXCEPTION 'immutable deposit receipt'; END IF;
          IF NEW.status='REVIEW' AND (NEW.pending_obligation,NEW.intent_id,NEW.manual_case_id,NEW.user_id,NEW.ledger_transaction_id,NEW.recharge_request_id,NEW.caibi_ledger_transaction_id) IS NOT DISTINCT FROM (OLD.pending_obligation,OLD.intent_id,OLD.manual_case_id,OLD.user_id,OLD.ledger_transaction_id,OLD.recharge_request_id,OLD.caibi_ledger_transaction_id) THEN RETURN NEW; END IF;
          IF NEW.status='CREDITED' AND NOT NEW.pending_obligation AND NEW.user_id IS NOT NULL THEN
            IF NEW.ledger_transaction_id IS NOT NULL AND NEW.recharge_request_id IS NULL AND NEW.caibi_ledger_transaction_id IS NULL AND ((NEW.intent_id IS NOT NULL) <> (NEW.manual_case_id IS NOT NULL)) THEN
              IF EXISTS (SELECT 1 FROM wallet_recharge_receipt_reservations r WHERE r.receipt_id=NEW.id) THEN RAISE EXCEPTION 'receipt reserved for support recharge'; END IF;
              IF NEW.manual_case_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM wallet_manual_deposit_cases c JOIN wallet_manual_deposit_decisions d ON d.case_id=c.id AND d.decision='APPROVED' WHERE c.id=NEW.manual_case_id AND c.receipt_id=NEW.id AND c.user_id=NEW.user_id) THEN RAISE EXCEPTION 'manual deposit case requires reciprocal approved decision'; END IF;
              RETURN NEW;
            END IF;
            IF NEW.ledger_transaction_id IS NULL AND NEW.intent_id IS NULL AND NEW.manual_case_id IS NULL AND NEW.recharge_request_id IS NOT NULL AND NEW.caibi_ledger_transaction_id IS NOT NULL AND EXISTS (
              SELECT 1 FROM wallet_recharge_receipt_reservations r
              JOIN recharge_credit_bindings b ON b.request_id=r.request_id
              JOIN adjustment_requests a ON a.id=b.adjustment_id
              WHERE r.receipt_id=NEW.id AND r.request_id=NEW.recharge_request_id AND r.user_id=NEW.user_id
              AND r.state='CONSUMED' AND r.ledger_transaction_id=NEW.caibi_ledger_transaction_id
              AND a.status='EXECUTED' AND a.ledger_transaction_id=NEW.caibi_ledger_transaction_id AND a.user_id=NEW.user_id
            ) THEN RETURN NEW; END IF;
          END IF;
          RAISE EXCEPTION 'immutable deposit receipt'; END; $$ LANGUAGE plpgsql""")


def downgrade():
    raise RuntimeError('retain support order and receipt audit; rollback application only')
