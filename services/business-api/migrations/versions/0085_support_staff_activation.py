"""Purpose-bound activation for existing support identities."""
from alembic import op
import sqlalchemy as sa

revision = '0085_support_staff_activation'
down_revision = '0084_support_order_workflow'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table('identity_staff_activation_challenges',
        sa.Column('id', sa.String(64), primary_key=True),
        sa.Column('user_id', sa.String(36), sa.ForeignKey('users.id'), nullable=False),
        sa.Column('identity_digest', sa.String(64), nullable=False),
        sa.Column('channel', sa.String(8), nullable=False),
        sa.Column('expires_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('consumed_at', sa.DateTime(timezone=True)))
    op.create_index('ix_identity_staff_activation_challenges_user_id',
        'identity_staff_activation_challenges', ['user_id'])
    op.create_table('identity_staff_activations',
        sa.Column('user_id', sa.String(36), sa.ForeignKey('users.id'), primary_key=True),
        sa.Column('identity_digest', sa.String(64), nullable=False),
        sa.Column('activated_at', sa.DateTime(timezone=True), nullable=False))


def downgrade():
    raise RuntimeError('Preserve activation audit and challenges; use a forward migration')
