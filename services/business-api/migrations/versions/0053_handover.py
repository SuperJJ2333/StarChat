"""Immutable evidence for the initial no-funds monitor handover."""
from alembic import op
import sqlalchemy as sa

revision = '0053_handover'
down_revision = '0052_manual_control'
branch_labels = None
depends_on = None


def col(name, kind, *, pk=False):
    return sa.Column(name, kind, primary_key=pk, nullable=False)


def upgrade():
    stamp=lambda: col('created_at',sa.DateTime(timezone=True))
    actor=lambda: col('actor_id',sa.String(36))
    reason=lambda: col('reason_code',sa.String(100))
    digest=lambda: col('manifest_digest',sa.String(64))
    payload=lambda: col('payload_digest',sa.String(64))
    op.create_table('wallet_handover_preparations',
        col('id',sa.String(36),pk=True),actor(),col('idempotency_key',sa.String(128)),payload(),digest(),
        col('manifest',sa.JSON()),stamp(),col('expires_at',sa.DateTime(timezone=True)),
        sa.UniqueConstraint('actor_id','idempotency_key',name='uq_wallet_handover_prepare'))
    op.create_table('wallet_handover_commands',
        col('idempotency_key',sa.String(128),pk=True),payload(),col('result',sa.JSON()),stamp())
    op.create_table('wallet_incident_handover_dispositions',
        col('incident_id',sa.String(36),pk=True),col('generation',sa.Integer(),pk=True),
        col('handover_id',sa.String(36)),digest(),col('successor_scope',sa.String(64)),
        col('disposition',sa.String(40)),actor(),reason(),stamp())
    op.create_table('outbox_handover_notices',col('id',sa.String(36),pk=True),
        col('preparation_id',sa.String(36)),digest(),payload(),actor(),reason(),stamp(),
        sa.UniqueConstraint('preparation_id',name='uq_outbox_handover_preparation'),
        sa.UniqueConstraint('manifest_digest',name='uq_outbox_handover_manifest'))
    op.create_table('outbox_handover_members',col('event_id',sa.String(36),pk=True),
        col('notice_id',sa.String(36)),col('original_snapshot',sa.JSON()),digest(),stamp())
    op.create_table('outbox_handover_receipts',col('notice_id',sa.String(36),pk=True),
        payload(),col('transport',sa.String(16)),stamp())
    op.create_table('outbox_handover_dispositions',col('event_id',sa.String(36),pk=True),
        col('notice_id',sa.String(36)),digest(),col('disposition',sa.String(40)),actor(),reason(),stamp())
    if op.get_bind().dialect.name == 'postgresql':
        op.execute("""CREATE FUNCTION wallet_handover_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN RAISE EXCEPTION 'immutable wallet handover evidence'; END $$;""")
        for table in ('wallet_handover_preparations','wallet_handover_commands','wallet_incident_handover_dispositions',
                      'outbox_handover_notices','outbox_handover_members','outbox_handover_receipts','outbox_handover_dispositions'):
            op.execute(f'CREATE TRIGGER {table}_immutable BEFORE UPDATE OR DELETE ON {table} '
                       'FOR EACH ROW EXECUTE FUNCTION wallet_handover_immutable()')


def downgrade():
    raise RuntimeError('handover evidence must be retained; roll back application only')
