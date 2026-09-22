"""Expand deposit intent lifecycle and retain cancellation command receipts."""
from alembic import op
import sqlalchemy as sa

revision = '0082_deposit_intent_cancel'
down_revision = '0081_recharge_binding_history'
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table('wallet_deposit_intents') as batch:
        batch.drop_constraint('ck_wallet_deposit_intent_status', type_='check')
        batch.create_check_constraint('ck_wallet_deposit_intent_status',
            "status IN ('OPEN', 'EXPIRED', 'CLOSED_BY_REBIND', 'FULFILLED', 'CANCELLED')")
    op.create_table('wallet_deposit_intent_cancellations',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('user_id', sa.String(36), nullable=False),
        sa.Column('intent_id', sa.String(36), sa.ForeignKey('wallet_deposit_intents.id'), nullable=False),
        sa.Column('idempotency_key', sa.String(128), nullable=False),
        sa.Column('response', sa.JSON(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint('user_id', 'idempotency_key', name='uq_deposit_intent_cancel_request'))
    if op.get_bind().dialect.name == 'postgresql':
        op.execute("""CREATE OR REPLACE FUNCTION wallet_deposit_intent_immutable() RETURNS trigger AS $$
        BEGIN
          IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'deposit intent history must be retained'; END IF;
          IF (to_jsonb(NEW) - ARRAY['status', 'closed_at'])
             IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['status', 'closed_at'])
             OR OLD.status <> 'OPEN'
             OR NEW.status NOT IN ('EXPIRED', 'CLOSED_BY_REBIND', 'FULFILLED', 'CANCELLED')
             OR NEW.closed_at IS NULL
          THEN RAISE EXCEPTION 'immutable deposit intent'; END IF;
          RETURN NEW;
        END; $$ LANGUAGE plpgsql""")
        op.execute("""CREATE FUNCTION wallet_deposit_intent_cancel_immutable() RETURNS trigger AS $$
        BEGIN RAISE EXCEPTION 'deposit cancellation history must be retained'; END;
        $$ LANGUAGE plpgsql""")
        op.execute("""CREATE TRIGGER wallet_deposit_intent_cancel_immutable BEFORE UPDATE OR DELETE
        ON wallet_deposit_intent_cancellations FOR EACH ROW EXECUTE FUNCTION wallet_deposit_intent_cancel_immutable()""")


def downgrade():
    raise RuntimeError('Cancellation history is append-only; use a forward migration')
