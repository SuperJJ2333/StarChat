"""Independent administrator operation password and immutable setup history."""
from alembic import op
import sqlalchemy as sa

revision = '0054_admin_password'
down_revision = '0053_handover'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table('identity_admin_operation_credentials',
        sa.Column('user_id',sa.String(36),primary_key=True),
        sa.Column('password_hash',sa.Text(),nullable=False),
        sa.Column('version',sa.Integer(),nullable=False),
        sa.Column('created_at',sa.DateTime(timezone=True),nullable=False),
        sa.Column('updated_at',sa.DateTime(timezone=True),nullable=False),
        sa.CheckConstraint('version > 0',name='ck_admin_operation_version'))
    op.create_table('identity_admin_operation_attempts',
        sa.Column('user_id',sa.String(36),primary_key=True),
        sa.Column('failed_count',sa.Integer(),nullable=False),
        sa.Column('window_started_at',sa.DateTime(timezone=True),nullable=False),
        sa.Column('locked_until',sa.DateTime(timezone=True),nullable=True),
        sa.CheckConstraint('failed_count >= 0',name='ck_admin_operation_failed_count'))
    op.create_table('identity_admin_operation_commands',
        sa.Column('id',sa.String(36),primary_key=True),
        sa.Column('actor_id',sa.String(36),nullable=False),
        sa.Column('idempotency_key',sa.String(128),nullable=False),
        sa.Column('request_hash',sa.Text(),nullable=False),
        sa.Column('credential_version',sa.Integer(),nullable=False),
        sa.Column('result',sa.JSON(),nullable=False),
        sa.Column('created_at',sa.DateTime(timezone=True),nullable=False),
        sa.UniqueConstraint('actor_id','idempotency_key',name='uq_admin_operation_actor_key'))
    if op.get_bind().dialect.name == 'postgresql':
        op.execute("""CREATE FUNCTION prevent_admin_operation_command_change() RETURNS trigger
            LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'admin operation command is immutable'; END; $$""")
        op.execute('CREATE TRIGGER admin_operation_command_immutable BEFORE UPDATE OR DELETE ON identity_admin_operation_commands FOR EACH ROW EXECUTE FUNCTION prevent_admin_operation_command_change()')


def downgrade():
    # Roll back application images while retaining credential and audit history.
    raise RuntimeError('Retain expanded authentication schema; use application rollback')
