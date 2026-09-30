"""Allow a claimed, never-broadcast payout to enter retained VOIDED history."""
from alembic import op
import sqlalchemy as sa

revision = '0093_unbroadcast_payout_void'
down_revision = '0092_admin_session_entry_mode'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('wallet_manual_payout_orders', sa.Column('version', sa.Integer(), nullable=False, server_default='1'))
    with op.batch_alter_table('wallet_manual_payout_orders') as batch:
        batch.drop_constraint('ck_manual_payout_status', type_='check')
        batch.drop_constraint('ck_manual_payout_claim', type_='check')
        batch.create_check_constraint('ck_manual_payout_status',
            "status IN ('REQUESTED','CLAIMED','UNKNOWN','SETTLED','CANCELLED','VOIDED')")
        batch.create_check_constraint('ck_manual_payout_claim',
            "(status IN ('REQUESTED','CANCELLED') AND claimed_by IS NULL AND claimed_at IS NULL AND candidate_txid IS NULL) "
            "OR (status IN ('CLAIMED','UNKNOWN','SETTLED','VOIDED') AND claimed_by IS NOT NULL AND claimed_at IS NOT NULL)")
        batch.create_check_constraint('ck_manual_payout_voided', "status != 'VOIDED' OR candidate_txid IS NULL")
    if op.get_bind().dialect.name == 'postgresql':
        op.execute("""CREATE OR REPLACE FUNCTION wallet_manual_order_guard() RETURNS trigger AS $$
        BEGIN
          IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'manual payout history must be retained'; END IF;
          IF OLD.status IN ('SETTLED','CANCELLED','VOIDED') AND to_jsonb(NEW) IS DISTINCT FROM to_jsonb(OLD)
             OR (NEW.id,NEW.quote_id,NEW.user_id,NEW.amount,NEW.digest,NEW.created_at)
                IS DISTINCT FROM (OLD.id,OLD.quote_id,OLD.user_id,OLD.amount,OLD.digest,OLD.created_at)
             OR (OLD.claimed_by IS NOT NULL AND NEW.claimed_by IS DISTINCT FROM OLD.claimed_by)
             OR (OLD.claimed_at IS NOT NULL AND NEW.claimed_at IS DISTINCT FROM OLD.claimed_at)
             OR (OLD.candidate_txid IS NOT NULL AND NEW.candidate_txid IS DISTINCT FROM OLD.candidate_txid)
          THEN RAISE EXCEPTION 'immutable manual payout order'; END IF;
          IF NEW.status <> OLD.status AND NOT (
            (OLD.status = 'REQUESTED' AND NEW.status IN ('CLAIMED','CANCELLED')) OR
            (OLD.status = 'CLAIMED' AND NEW.status IN ('UNKNOWN','SETTLED')) OR
            (OLD.status = 'UNKNOWN' AND NEW.status IN ('SETTLED','VOIDED')))
          THEN RAISE EXCEPTION 'illegal manual payout transition'; END IF;
          IF NEW.status = 'VOIDED' AND OLD.status <> 'VOIDED' AND
             (NEW.candidate_txid IS NOT NULL OR EXISTS (
                SELECT 1 FROM wallet_manual_payout_candidates WHERE order_id = NEW.id) OR EXISTS (
                SELECT 1 FROM wallet_manual_payout_events WHERE order_id = NEW.id))
          THEN RAISE EXCEPTION 'payout candidate or event prevents void'; END IF;
          RETURN NEW;
        END; $$ LANGUAGE plpgsql""")


def downgrade():
    raise RuntimeError('VOIDED payout history must be retained; roll back application only')
