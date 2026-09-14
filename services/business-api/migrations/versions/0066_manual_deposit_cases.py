"""Expand receipt attribution for independently reviewed manual deposit cases."""
from alembic import op
import sqlalchemy as sa

revision = '0066_manual_deposit_cases'
down_revision = '0065_support_profiles'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table('wallet_manual_deposit_cases',
        sa.Column('id',sa.String(36),primary_key=True), sa.Column('receipt_id',sa.String(36),sa.ForeignKey('wallet_deposit_receipts.id'),nullable=False),
        sa.Column('user_id',sa.String(36),nullable=False),sa.Column('binding_id',sa.String(36),sa.ForeignKey('wallet_bindings.id'),nullable=False),
        sa.Column('binding_version',sa.Integer(),nullable=False),sa.Column('binding_effective_from_block',sa.BigInteger(),nullable=False),sa.Column('binding_effective_to_block',sa.BigInteger()),
        sa.Column('facts_digest',sa.String(64),nullable=False),sa.Column('actor_id',sa.String(36),nullable=False),sa.Column('idempotency_key',sa.String(128),nullable=False),sa.Column('payload_digest',sa.String(64),nullable=False),sa.Column('reason_detail_digest',sa.String(64),nullable=False),sa.Column('reason_detail',sa.String(500),nullable=False),sa.Column('ownership_attestation',sa.Boolean(),nullable=False),sa.Column('created_at',sa.DateTime(timezone=True),nullable=False),sa.UniqueConstraint('actor_id','idempotency_key',name='uq_manual_deposit_case_key'))
    op.create_table('wallet_manual_deposit_decisions',sa.Column('id',sa.String(36),primary_key=True),sa.Column('case_id',sa.String(36),sa.ForeignKey('wallet_manual_deposit_cases.id'),nullable=False),sa.Column('actor_id',sa.String(36),nullable=False),sa.Column('decision',sa.String(16),nullable=False),sa.Column('idempotency_key',sa.String(128),nullable=False),sa.Column('payload_digest',sa.String(64),nullable=False),sa.Column('reason_detail_digest',sa.String(64),nullable=False),sa.Column('reason_detail',sa.String(500),nullable=False),sa.Column('created_at',sa.DateTime(timezone=True),nullable=False),sa.UniqueConstraint('case_id',name='uq_manual_deposit_decision_case'),sa.UniqueConstraint('actor_id','idempotency_key',name='uq_manual_deposit_decision_key'),sa.CheckConstraint("decision IN ('APPROVED','REJECTED')",name='ck_manual_deposit_decision'))
    with op.batch_alter_table('wallet_deposit_receipts') as batch:
        batch.add_column(sa.Column('manual_case_id',sa.String(36),sa.ForeignKey('wallet_manual_deposit_cases.id')))
        batch.create_unique_constraint('uq_wallet_deposit_receipt_manual_case',['manual_case_id'])
    if op.get_bind().dialect.name == 'postgresql':
        op.execute('DROP TRIGGER wallet_deposit_receipt_immutable ON wallet_deposit_receipts')
        op.execute('DROP FUNCTION wallet_deposit_receipt_immutable()')
        op.execute("""CREATE FUNCTION wallet_deposit_receipt_immutable() RETURNS trigger AS $$
        BEGIN
          IF TG_OP='DELETE' THEN RAISE EXCEPTION 'deposit receipt history must be retained'; END IF;
          IF (to_jsonb(NEW) - ARRAY['status','reason_code','pending_obligation','intent_id','manual_case_id','user_id','ledger_transaction_id']) IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['status','reason_code','pending_obligation','intent_id','manual_case_id','user_id','ledger_transaction_id']) OR OLD.status<>'REVIEW' THEN RAISE EXCEPTION 'immutable deposit receipt'; END IF;
          IF NEW.status='REVIEW' AND (NEW.pending_obligation,NEW.intent_id,NEW.manual_case_id,NEW.user_id,NEW.ledger_transaction_id) IS NOT DISTINCT FROM (OLD.pending_obligation,OLD.intent_id,OLD.manual_case_id,OLD.user_id,OLD.ledger_transaction_id) THEN RETURN NEW; END IF;
          IF NEW.status='CREDITED' AND NOT NEW.pending_obligation AND NEW.user_id IS NOT NULL AND NEW.ledger_transaction_id IS NOT NULL AND ((NEW.intent_id IS NOT NULL) <> (NEW.manual_case_id IS NOT NULL)) THEN
            IF NEW.manual_case_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM wallet_manual_deposit_cases c JOIN wallet_manual_deposit_decisions d ON d.case_id=c.id AND d.decision='APPROVED' WHERE c.id=NEW.manual_case_id AND c.receipt_id=NEW.id AND c.user_id=NEW.user_id) THEN RAISE EXCEPTION 'manual deposit case requires reciprocal approved decision'; END IF;
            RETURN NEW;
          END IF;
          RAISE EXCEPTION 'immutable deposit receipt'; END; $$ LANGUAGE plpgsql""")
        op.execute("CREATE TRIGGER wallet_deposit_receipt_immutable BEFORE UPDATE OR DELETE ON wallet_deposit_receipts FOR EACH ROW EXECUTE FUNCTION wallet_deposit_receipt_immutable()")
        for table in ('wallet_manual_deposit_cases','wallet_manual_deposit_decisions'):
            op.execute(f"CREATE TRIGGER {table}_immutable BEFORE UPDATE OR DELETE ON {table} FOR EACH ROW EXECUTE FUNCTION wallet_repair_immutable()")


def downgrade():
    raise RuntimeError('retain manual deposit financial history; use application rollback')
