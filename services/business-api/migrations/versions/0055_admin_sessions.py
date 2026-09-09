"""Expand identity with a current management-session pointer and absolute deadline."""
from alembic import op
import sqlalchemy as sa

revision = '0055_admin_sessions'
down_revision = '0054_admin_password'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table('identity_admin_sessions',
        sa.Column('user_id', sa.String(36), sa.ForeignKey('users.id'), primary_key=True),
        sa.Column('family_id', sa.String(36), sa.ForeignKey('refresh_token_families.id'), nullable=False, unique=True),
        sa.Column('expires_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('authenticated_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False))


def downgrade():
    raise RuntimeError('Retain expanded authentication schema and revoked families; use application rollback')
