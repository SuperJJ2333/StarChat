"""Add private-wallet proofs and version history; never activate legacy addresses."""
from alembic import op
import sqlalchemy as sa

revision = '0042_wallet_binding'
down_revision = '0041_wallet_operations'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table('wallet_address_owners',
        sa.Column('address', sa.String(34), primary_key=True),
        sa.Column('user_id', sa.String(36), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False))
    op.create_table('wallet_binding_states',
        sa.Column('user_id', sa.String(36), primary_key=True),
        sa.Column('version', sa.Integer(), nullable=False),
        sa.Column('active_binding_id', sa.String(36), unique=True),
        sa.Column('pending_binding_id', sa.String(36), unique=True),
        sa.Column('last_rebind_at', sa.DateTime(timezone=True)))
    op.create_table('wallet_bindings',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('user_id', sa.String(36), nullable=False),
        sa.Column('address', sa.String(34), sa.ForeignKey('wallet_address_owners.address'), nullable=False),
        sa.Column('version', sa.Integer(), nullable=False),
        sa.Column('status', sa.String(16), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('activated_at', sa.DateTime(timezone=True)),
        sa.Column('effective_from_block', sa.BigInteger()),
        sa.Column('effective_to_block', sa.BigInteger()),
        sa.Column('barrier_height', sa.BigInteger()),
        sa.Column('barrier_block_id', sa.String(64)),
        sa.Column('barrier_source_ids', sa.JSON(none_as_null=True)),
        sa.Column('barrier_observed_at', sa.DateTime(timezone=True)),
        sa.UniqueConstraint('user_id', 'version', name='uq_wallet_binding_version'),
        sa.CheckConstraint("status IN ('PENDING', 'ACTIVE', 'RETIRED')", name='ck_wallet_binding_status'),
        sa.CheckConstraint("(status = 'PENDING' AND activated_at IS NULL AND effective_from_block IS NULL AND effective_to_block IS NULL AND barrier_height IS NULL AND barrier_block_id IS NULL AND barrier_source_ids IS NULL AND barrier_observed_at IS NULL) OR (status IN ('ACTIVE', 'RETIRED') AND activated_at IS NOT NULL AND effective_from_block IS NOT NULL AND barrier_height IS NOT NULL AND barrier_height >= 0 AND effective_from_block = barrier_height + 1 AND barrier_block_id IS NOT NULL AND barrier_source_ids IS NOT NULL AND barrier_observed_at IS NOT NULL AND ((status = 'ACTIVE' AND effective_to_block IS NULL) OR (status = 'RETIRED' AND effective_to_block IS NOT NULL)))", name='ck_wallet_binding_evidence'),
        sa.CheckConstraint('effective_to_block IS NULL OR effective_to_block > effective_from_block', name='ck_wallet_binding_interval'))
    for status in ('ACTIVE', 'PENDING'):
        op.create_index('uq_wallet_binding_' + status.lower(), 'wallet_bindings', ['user_id'], unique=True,
            postgresql_where=sa.text("status = '" + status + "'"), sqlite_where=sa.text("status = '" + status + "'"))
    op.create_table('wallet_binding_challenges',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('user_id', sa.String(36), nullable=False),
        sa.Column('session_digest', sa.String(64), nullable=False),
        sa.Column('domain', sa.String(255), nullable=False),
        sa.Column('network', sa.String(32), nullable=False),
        sa.Column('address', sa.String(34), nullable=False),
        sa.Column('expected_version', sa.Integer(), nullable=False),
        sa.Column('message', sa.Text(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('expires_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('consumed_at', sa.DateTime(timezone=True)))
    op.create_table('wallet_binding_requests',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('user_id', sa.String(36), nullable=False),
        sa.Column('operation', sa.String(16), nullable=False),
        sa.Column('idempotency_key', sa.String(128), nullable=False),
        sa.Column('digest', sa.String(64), nullable=False),
        sa.Column('response', sa.JSON(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint('user_id', 'operation', 'idempotency_key', name='uq_wallet_binding_request'))
    # Fail closed when no wallet control row was present; preserve an existing row.
    op.execute(sa.text("INSERT INTO wallet_controls (id, withdrawals_paused, pause_reason) "
        "SELECT 'global', true, 'WALLET_BINDING_SETUP' WHERE NOT EXISTS (SELECT 1 FROM wallet_controls WHERE id = 'global')"))
    if op.get_bind().dialect.name == 'postgresql':
        op.execute("""CREATE FUNCTION wallet_binding_ownership_immutable() RETURNS trigger AS $$
        BEGIN RAISE EXCEPTION 'wallet address ownership is immutable'; END;
        $$ LANGUAGE plpgsql""")
        op.execute("""CREATE TRIGGER wallet_address_ownership_immutable BEFORE UPDATE OR DELETE
        ON wallet_address_owners FOR EACH ROW EXECUTE FUNCTION wallet_binding_ownership_immutable()""")
        op.execute("""CREATE FUNCTION wallet_binding_history_guard() RETURNS trigger AS $$
        BEGIN
          IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'wallet binding history is immutable'; END IF;
          IF (NEW.id, NEW.user_id, NEW.address, NEW.version, NEW.created_at)
             IS DISTINCT FROM (OLD.id, OLD.user_id, OLD.address, OLD.version, OLD.created_at)
             OR OLD.status = 'RETIRED'
             OR (OLD.status = 'ACTIVE' AND (NEW.status <> 'RETIRED' OR NEW.effective_to_block IS NULL
                 OR (NEW.activated_at, NEW.effective_from_block, NEW.barrier_height, NEW.barrier_block_id, NEW.barrier_source_ids::text, NEW.barrier_observed_at)
                    IS DISTINCT FROM (OLD.activated_at, OLD.effective_from_block, OLD.barrier_height, OLD.barrier_block_id, OLD.barrier_source_ids::text, OLD.barrier_observed_at)))
          THEN RAISE EXCEPTION 'wallet binding history is immutable'; END IF;
          RETURN NEW;
        END; $$ LANGUAGE plpgsql""")
        op.execute("""CREATE TRIGGER wallet_binding_history_guard BEFORE UPDATE OR DELETE
        ON wallet_bindings FOR EACH ROW EXECUTE FUNCTION wallet_binding_history_guard()""")


def downgrade():
    # Operational rollback reverts application code and retains ownership history.
    raise RuntimeError('Wallet binding history must be retained; use application rollback')
