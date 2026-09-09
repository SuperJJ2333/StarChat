"""Append-only evidence for manual-wallet reserve publication."""
from alembic import op
import sqlalchemy as sa

revision = '0050_manual_reserve'
down_revision = '0049_funding_coverage'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table('ledger_manual_reserve_evaluations',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('idempotency_key', sa.String(128), nullable=False),
        sa.Column('payload_digest', sa.String(64), nullable=False),
        sa.Column('source_identity', sa.String(64), nullable=False),
        sa.Column('observation_id', sa.BigInteger(), nullable=False),
        sa.Column('cut_digest', sa.String(64), nullable=False),
        sa.Column('expected_version', sa.BigInteger()),
        sa.Column('result_version', sa.BigInteger(), nullable=False),
        sa.Column('evidence', sa.JSON(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint('idempotency_key', name='uq_manual_reserve_idempotency'),
        sa.CheckConstraint('observation_id > 0', name='ck_manual_reserve_observation'),
        sa.CheckConstraint('expected_version IS NULL OR expected_version >= 1', name='ck_manual_reserve_expected'),
        sa.CheckConstraint('result_version >= 1', name='ck_manual_reserve_result'),
        sa.CheckConstraint('(expected_version IS NULL AND result_version = 1) OR '
                           '(expected_version IS NOT NULL AND result_version = expected_version + 1)',
                           name='ck_manual_reserve_version_step'))
    if op.get_bind().dialect.name == 'postgresql':
        op.execute("""
        CREATE FUNCTION ledger_manual_reserve_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          RAISE EXCEPTION 'immutable manual reserve evaluation';
        END $$;
        CREATE TRIGGER ledger_manual_reserve_immutable
        BEFORE UPDATE OR DELETE ON ledger_manual_reserve_evaluations
        FOR EACH ROW EXECUTE FUNCTION ledger_manual_reserve_immutable();
        """)


def downgrade():
    raise RuntimeError('reserve evaluation history must be retained; roll back application only')
