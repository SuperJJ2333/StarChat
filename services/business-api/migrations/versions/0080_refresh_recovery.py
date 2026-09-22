"""Expand-only mobile refresh operation recovery metadata; no plaintext credentials."""
from alembic import op
import sqlalchemy as sa

revision = '0080_refresh_recovery'
down_revision = '0071_direct_room_generations'
branch_labels = None
depends_on = None


def upgrade():
    # Downgrade intentionally retains these columns. Online re-upgrade must
    # therefore preserve existing metadata instead of adding duplicate columns.
    existing = set() if op.get_context().as_sql else {
        column['name'] for column in sa.inspect(op.get_bind()).get_columns('refresh_tokens')}
    if 'operation_hash' not in existing:
        op.add_column('refresh_tokens', sa.Column('operation_hash', sa.String(64), nullable=True))
    if 'result_key_version' not in existing:
        op.add_column('refresh_tokens', sa.Column('result_key_version', sa.Integer(), nullable=True))


def downgrade():
    # Rollback keeps recovery metadata for already-issued mobile clients.
    pass
