"""Expand-only bounded friend discovery index.

PostgreSQL builds concurrently outside a transaction. An interrupted invalid
index stops retry explicitly: inspect its task ownership, drop only that invalid
index CONCURRENTLY, and rerun. Never drop data, constraints or valid indexes.
Downgrade retains this optional read index so application rollback is safe.
"""
from alembic import op

revision = '0090_friend_discovery_index'
down_revision = '0089_username_claims'
branch_labels = None
depends_on = None

_PRECHECK = """
DO $discovery$
DECLARE existing record;
BEGIN
  SELECT i.indisvalid, i.indisunique, i.indnkeyatts, i.indnatts, i.indrelid, i.indpred, am.amname,
         pg_get_indexdef(i.indexrelid, 1, true) AS first_key,
         regexp_replace(replace(pg_get_expr(i.indexprs, i.indrelid), '::text', ''), '[[:space:]()]', '', 'g') AS expressions
    INTO existing
    FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
    JOIN pg_am am ON am.oid = c.relam
   WHERE c.relnamespace = current_schema()::regnamespace
     AND c.relname = 'ix_users_discovery_handle';
  IF FOUND THEN
    IF NOT existing.indisvalid THEN
      RAISE EXCEPTION 'Invalid task index ix_users_discovery_handle; inspect ownership, drop only this invalid index CONCURRENTLY, then retry';
    END IF;
    IF existing.indisunique OR existing.indnkeyatts <> 3 OR existing.indnatts <> 3
       OR existing.indpred IS NOT NULL OR existing.amname <> 'btree' OR existing.indrelid <> 'users'::regclass
       OR existing.first_key <> 'status'
       OR existing.expressions IS DISTINCT FROM 'lengthusername_normalized,substrusername_normalized,1,lengthusername_normalized-2' THEN
      RAISE EXCEPTION 'Unexpected existing ix_users_discovery_handle definition; review without overwriting';
    END IF;
  END IF;
END $discovery$;
"""


def upgrade():
    if op.get_context().dialect.name == 'postgresql':
        op.execute(_PRECHECK)
        with op.get_context().autocommit_block():
            op.execute('CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_users_discovery_handle '
                'ON users (status, length(username_normalized), substr(username_normalized, 1, length(username_normalized) - 2))')
    else:
        op.execute('CREATE INDEX IF NOT EXISTS ix_users_discovery_handle '
            'ON users (status, length(username_normalized), substr(username_normalized, 1, length(username_normalized) - 2))')


def downgrade():
    pass
