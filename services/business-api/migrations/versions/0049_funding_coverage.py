"""Retain immutable per-log discovery facts and monotonic verification verdicts."""
from alembic import op
import sqlalchemy as sa

revision = '0049_funding_coverage'
down_revision = '0048_funding_scan'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table('wallet_funding_coverage_events',
        sa.Column('id',sa.String(36),primary_key=True),
        sa.Column('source_identity',sa.String(64),nullable=False),
        sa.Column('source_rowid',sa.BigInteger(),nullable=False),
        sa.Column('txid',sa.String(64),nullable=False),
        sa.Column('log_index',sa.BigInteger(),nullable=False),
        sa.Column('amount_units',sa.String(100),nullable=False),
        sa.Column('from_address',sa.String(34),nullable=False),
        sa.Column('to_address',sa.String(34),nullable=False),
        sa.Column('block_number',sa.BigInteger(),nullable=False),
        sa.Column('timestamp_ms',sa.BigInteger(),nullable=False),
        sa.Column('facts_digest',sa.String(64),nullable=False),
        sa.Column('status',sa.String(16),nullable=False),
        sa.Column('created_at',sa.DateTime(timezone=True),nullable=False),
        sa.Column('proof',sa.JSON(none_as_null=True)),
        sa.Column('verified_at',sa.DateTime(timezone=True)),
        sa.Column('conflict_at',sa.DateTime(timezone=True)),
        sa.UniqueConstraint('source_identity','source_rowid',name='uq_wallet_coverage_source_row'),
        sa.UniqueConstraint('source_identity','txid','log_index',name='uq_wallet_coverage_source_log'),
        sa.CheckConstraint("status IN ('PENDING','VERIFIED','CONFLICT')",name='ck_wallet_coverage_status'),
        sa.CheckConstraint('source_rowid > 0 AND log_index >= 0 AND block_number >= 0 AND timestamp_ms >= 0',name='ck_wallet_coverage_numbers'),
        sa.CheckConstraint("(status = 'PENDING' AND proof IS NULL AND verified_at IS NULL AND conflict_at IS NULL) OR (status = 'VERIFIED' AND proof IS NOT NULL AND verified_at IS NOT NULL AND conflict_at IS NULL) OR (status = 'CONFLICT' AND conflict_at IS NOT NULL AND ((proof IS NULL AND verified_at IS NULL) OR (proof IS NOT NULL AND verified_at IS NOT NULL)))",name='ck_wallet_coverage_shape'))
    if op.get_bind().dialect.name == 'postgresql':
        op.execute("""
        CREATE FUNCTION wallet_funding_coverage_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable funding coverage record'; END IF;
          IF ROW(NEW.id,NEW.source_identity,NEW.source_rowid,NEW.txid,NEW.log_index,NEW.amount_units,
              NEW.from_address,NEW.to_address,NEW.block_number,NEW.timestamp_ms,NEW.facts_digest,NEW.created_at)
            IS DISTINCT FROM ROW(OLD.id,OLD.source_identity,OLD.source_rowid,OLD.txid,OLD.log_index,OLD.amount_units,
              OLD.from_address,OLD.to_address,OLD.block_number,OLD.timestamp_ms,OLD.facts_digest,OLD.created_at)
          THEN RAISE EXCEPTION 'immutable funding coverage facts'; END IF;
          IF OLD.status = 'CONFLICT' OR (OLD.status = 'VERIFIED' AND NEW.status <> 'CONFLICT')
          THEN RAISE EXCEPTION 'immutable funding coverage verdict'; END IF;
          IF (OLD.proof IS NOT NULL AND NEW.proof::jsonb IS DISTINCT FROM OLD.proof::jsonb)
            OR (OLD.verified_at IS NOT NULL AND NEW.verified_at IS DISTINCT FROM OLD.verified_at)
            OR (OLD.conflict_at IS NOT NULL AND NEW.conflict_at IS DISTINCT FROM OLD.conflict_at)
          THEN RAISE EXCEPTION 'immutable funding coverage proof'; END IF;
          RETURN NEW;
        END $$;
        CREATE TRIGGER wallet_funding_coverage_immutable BEFORE UPDATE OR DELETE ON wallet_funding_coverage_events
        FOR EACH ROW EXECUTE FUNCTION wallet_funding_coverage_immutable();
        """)


def downgrade():
    raise RuntimeError('funding coverage history must be retained; roll back application only')
