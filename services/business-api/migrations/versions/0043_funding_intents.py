"""Add immutable deposit intents without changing historical wallet records."""
from alembic import op
import sqlalchemy as sa

revision = '0043_funding_intents'
down_revision = '0042_wallet_binding'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table('wallet_deposit_intents',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('user_id', sa.String(36), nullable=False),
        sa.Column('idempotency_key', sa.String(128), nullable=False),
        sa.Column('binding_id', sa.String(36), sa.ForeignKey('wallet_bindings.id'), nullable=False),
        sa.Column('binding_version', sa.Integer(), nullable=False),
        sa.Column('binding_effective_from_block', sa.BigInteger(), nullable=False),
        sa.Column('source_address', sa.String(34), nullable=False),
        sa.Column('official_address', sa.String(34), nullable=False),
        sa.Column('official_config_version', sa.String(128), nullable=False),
        sa.Column('network', sa.String(32), nullable=False),
        sa.Column('expected_amount', sa.Numeric(30, 6), nullable=False),
        sa.Column('rules_snapshot', sa.JSON(), nullable=False),
        sa.Column('status', sa.String(24), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('expires_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('closed_at', sa.DateTime(timezone=True)),
        sa.UniqueConstraint('user_id', 'idempotency_key', name='uq_wallet_deposit_intent_request'),
        sa.CheckConstraint("status IN ('OPEN', 'EXPIRED', 'CLOSED_BY_REBIND')", name='ck_wallet_deposit_intent_status'),
        sa.CheckConstraint('expected_amount >= 10 AND binding_version > 0 AND binding_effective_from_block >= 0',
            name='ck_wallet_deposit_intent_values'),
        sa.CheckConstraint('expires_at > created_at', name='ck_wallet_deposit_intent_expiry'),
        sa.CheckConstraint("(status = 'OPEN' AND closed_at IS NULL) OR (status <> 'OPEN' AND closed_at IS NOT NULL)",
            name='ck_wallet_deposit_intent_closure'))
    op.create_index('uq_wallet_deposit_intent_open', 'wallet_deposit_intents', ['user_id'], unique=True,
        postgresql_where=sa.text("status = 'OPEN'"), sqlite_where=sa.text("status = 'OPEN'"))
    if op.get_bind().dialect.name == 'postgresql':
        op.execute("""CREATE FUNCTION wallet_deposit_intent_immutable() RETURNS trigger AS $$
        BEGIN
          IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'deposit intent history must be retained'; END IF;
          IF (to_jsonb(NEW) - ARRAY['status', 'closed_at'])
             IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['status', 'closed_at'])
             OR OLD.status <> 'OPEN'
             OR NEW.status NOT IN ('EXPIRED', 'CLOSED_BY_REBIND')
             OR NEW.closed_at IS NULL
          THEN RAISE EXCEPTION 'immutable deposit intent'; END IF;
          RETURN NEW;
        END; $$ LANGUAGE plpgsql""")
        op.execute("""CREATE TRIGGER wallet_deposit_intent_immutable BEFORE UPDATE OR DELETE
        ON wallet_deposit_intents FOR EACH ROW EXECUTE FUNCTION wallet_deposit_intent_immutable()""")


def downgrade():
    raise RuntimeError('Deposit intent history must be retained; use application rollback')
