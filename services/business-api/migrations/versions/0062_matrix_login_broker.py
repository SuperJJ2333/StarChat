"""Persist opaque one-time grants and monotonically increasing login intents."""
from alembic import op
import sqlalchemy as sa

revision = '0062_matrix_login_broker'
down_revision = '0061_mobile_matrix_session'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table('identity_matrix_login_grants',
        sa.Column('token_hash', sa.String(64), primary_key=True),
        sa.Column('user_id', sa.String(36), sa.ForeignKey('users.id'), nullable=False),
        sa.Column('family_id', sa.String(36), sa.ForeignKey('refresh_token_families.id'), nullable=False),
        sa.Column('expires_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('consumed_at', sa.DateTime(timezone=True)))
    op.create_index('ix_identity_matrix_login_grants_user_id', 'identity_matrix_login_grants', ['user_id'])
    op.create_table('identity_matrix_login_generations',
        sa.Column('user_id', sa.String(36), sa.ForeignKey('users.id'), primary_key=True),
        sa.Column('generation', sa.BigInteger(), nullable=False))


def downgrade():
    raise RuntimeError('Retain consumed grants and generations; use application rollback')
