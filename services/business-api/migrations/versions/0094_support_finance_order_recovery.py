"""Expand support payout decisions and claim versions without rewriting history."""

from alembic import op
import sqlalchemy as sa


revision = '0094_support_finance_order_recovery'
down_revision = '0093_unbroadcast_payout_void'
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Alembic creates version_num as VARCHAR(32); this approved revision is longer.
    op.alter_column('alembic_version', 'version_num',
        existing_type=sa.String(32), type_=sa.String(64), existing_nullable=False)
    for column in (
        sa.Column('prepared_rate', sa.Numeric(20, 6)),
        sa.Column('prepared_receive', sa.Numeric(30, 6)),
        sa.Column('prepared_digest', sa.String(64)),
        sa.Column('prepared_version', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('evidence_actor_id', sa.String(36)),
        sa.Column('evidence_token_hash', sa.String(64)),
        sa.Column('evidence_version', sa.Integer(), nullable=False, server_default='0'),
    ):
        op.add_column('wallet_support_payout_states', column)
    op.add_column('recharge_requests',
        sa.Column('claim_version', sa.Integer(), nullable=False, server_default='0'))

    op.create_table('wallet_support_payout_rate_preparations',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('order_id', sa.String(36),
            sa.ForeignKey('wallet_manual_payout_orders.id'), nullable=False),
        sa.Column('version', sa.Integer(), nullable=False),
        sa.Column('rate', sa.Numeric(20, 6), nullable=False),
        sa.Column('receive', sa.Numeric(30, 6), nullable=False),
        sa.Column('digest', sa.String(64), nullable=False),
        sa.Column('reason_code', sa.String(80), nullable=False),
        sa.Column('actor_id', sa.String(36), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint('order_id', 'version', name='uq_support_payout_preparation_version'),
    )
    op.create_table('wallet_support_payout_rejections',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('order_id', sa.String(36),
            sa.ForeignKey('wallet_manual_payout_orders.id'), nullable=False),
        sa.Column('actor_id', sa.String(36), nullable=False),
        sa.Column('reason_code', sa.String(80), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint('order_id', name='uq_support_payout_rejection_order'),
    )
    if op.get_bind().dialect.name == 'postgresql':
        op.execute("""CREATE FUNCTION reject_support_payout_decision_mutation() RETURNS trigger AS $$
        BEGIN
          RAISE EXCEPTION 'support payout decision history is append-only';
        END;
        $$ LANGUAGE plpgsql""")
        for table in ('wallet_support_payout_rate_preparations', 'wallet_support_payout_rejections'):
            op.execute(f"""CREATE TRIGGER {table}_append_only
                BEFORE UPDATE OR DELETE ON {table}
                FOR EACH ROW EXECUTE FUNCTION reject_support_payout_decision_mutation()""")


def downgrade() -> None:
    raise RuntimeError('support payout decision history must be retained; use a forward migration')
