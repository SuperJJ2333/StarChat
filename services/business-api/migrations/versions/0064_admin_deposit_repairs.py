"""Expand append-only manual review cases and unique financial commands."""
from alembic import op
import sqlalchemy as sa

revision = '0064_admin_deposit_repairs'
down_revision = '0063_merge_wallet_access'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table('wallet_repair_previews',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('actor_id', sa.String(36), nullable=False),
        sa.Column('kind', sa.String(24), nullable=False),
        sa.Column('digest', sa.String(64), nullable=False),
        sa.Column('snapshot', sa.JSON(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('expires_at', sa.DateTime(timezone=True), nullable=False))
    op.create_table('wallet_repair_commands',
        sa.Column('operation_id', sa.String(36), primary_key=True),
        sa.Column('actor_id', sa.String(36), nullable=False),
        sa.Column('idempotency_key', sa.String(128), nullable=False),
        sa.Column('payload_digest', sa.String(64), nullable=False),
        sa.Column('preview_id', sa.String(36), sa.ForeignKey('wallet_repair_previews.id'), nullable=False),
        sa.Column('receipt_id', sa.String(36), sa.ForeignKey('wallet_deposit_receipts.id')),
        sa.Column('intent_id', sa.String(36), sa.ForeignKey('wallet_deposit_intents.id')),
        sa.Column('result', sa.JSON(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint('actor_id', 'idempotency_key', name='uq_wallet_repair_command_key'),
        sa.UniqueConstraint('receipt_id', name='uq_wallet_repair_receipt'),
        sa.UniqueConstraint('intent_id', name='uq_wallet_repair_intent'))
    if op.get_bind().dialect.name == 'postgresql':
        op.execute("""CREATE FUNCTION wallet_repair_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN RAISE EXCEPTION 'wallet repair records are append-only'; END $$""")
        for table in ('wallet_repair_previews', 'wallet_repair_commands'):
            op.execute(f'CREATE TRIGGER {table}_immutable BEFORE UPDATE OR DELETE ON {table} '
                'FOR EACH ROW EXECUTE FUNCTION wallet_repair_immutable()')


def downgrade():
    raise RuntimeError('Disable manual repairs and retain financial commands; use application rollback')
