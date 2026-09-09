"""Retain restriction provenance and audited manual control commands."""
from alembic import op
import sqlalchemy as sa

revision = '0052_manual_control'
down_revision = '0051_monitor_delivery'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table('ledger_outgoing_restrictions',
        sa.Column('scope', sa.String(64), primary_key=True),
        sa.Column('active', sa.Boolean(), nullable=False),
        sa.Column('epoch', sa.BigInteger(), nullable=False),
        sa.Column('reason_code', sa.String(100), nullable=False),
        sa.Column('actor_id', sa.String(36), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint('epoch >= 1', name='ck_ledger_restriction_epoch'))
    op.create_table('wallet_manual_control_states',
        sa.Column('id', sa.String(20), primary_key=True),
        sa.Column('epoch', sa.BigInteger(), nullable=False),
        sa.Column('owns_pause', sa.Boolean(), nullable=False),
        sa.Column('pause_reason', sa.String(255)),
        sa.Column('owns_safety', sa.Boolean(), nullable=False),
        sa.Column('safety_epoch', sa.BigInteger()),
        sa.Column('safety_reason', sa.String(255)),
        sa.Column('updated_at', sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint('epoch >= 1', name='ck_manual_control_epoch'))
    op.create_table('wallet_manual_control_commands',
        sa.Column('idempotency_key', sa.String(128), primary_key=True),
        sa.Column('payload_digest', sa.String(64), nullable=False),
        sa.Column('result', sa.JSON(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False))
    # Old aggregate freezes are intentionally not assigned a recoverable scope.
    if op.get_bind().dialect.name == 'postgresql':
        op.execute("""
        CREATE FUNCTION wallet_manual_control_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          RAISE EXCEPTION 'immutable manual control command';
        END $$;
        CREATE TRIGGER wallet_manual_control_immutable
        BEFORE UPDATE OR DELETE ON wallet_manual_control_commands
        FOR EACH ROW EXECUTE FUNCTION wallet_manual_control_immutable();
        """)


def downgrade():
    raise RuntimeError('restriction provenance and command history must be retained; roll back application only')
