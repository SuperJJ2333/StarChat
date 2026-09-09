"""Record finality policy without relabeling historical binding evidence."""
from alembic import op
import sqlalchemy as sa

revision = '0044_binding_policy'
down_revision = '0043_funding_intents'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('wallet_bindings', sa.Column('barrier_policy', sa.String(40),
        nullable=False, server_default='LEGACY_UNSPECIFIED'))
    if op.get_bind().dialect.name == 'postgresql':
        op.execute("""CREATE OR REPLACE FUNCTION wallet_binding_history_guard() RETURNS trigger AS $$
        BEGIN
          IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'wallet binding history is immutable'; END IF;
          IF (NEW.id, NEW.user_id, NEW.address, NEW.version, NEW.created_at)
             IS DISTINCT FROM (OLD.id, OLD.user_id, OLD.address, OLD.version, OLD.created_at)
             OR OLD.status = 'RETIRED'
             OR (OLD.status = 'ACTIVE' AND (NEW.status <> 'RETIRED' OR NEW.effective_to_block IS NULL
                 OR (NEW.activated_at, NEW.effective_from_block, NEW.barrier_height, NEW.barrier_block_id,
                     NEW.barrier_source_ids::text, NEW.barrier_observed_at, NEW.barrier_policy)
                    IS DISTINCT FROM (OLD.activated_at, OLD.effective_from_block, OLD.barrier_height, OLD.barrier_block_id,
                     OLD.barrier_source_ids::text, OLD.barrier_observed_at, OLD.barrier_policy)))
          THEN RAISE EXCEPTION 'wallet binding history is immutable'; END IF;
          RETURN NEW;
        END; $$ LANGUAGE plpgsql""")


def downgrade():
    raise RuntimeError('Binding policy history must be retained; use application rollback')
