"""Add current mobile Matrix device binding without modifying existing sessions."""
from alembic import op
import sqlalchemy as sa

revision = '0061_mobile_matrix_session'
down_revision = '0060_merge_release_parity'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table('identity_mobile_matrix_sessions',
        sa.Column('user_id', sa.String(36), sa.ForeignKey('users.id'), primary_key=True),
        sa.Column('family_id', sa.String(36), sa.ForeignKey('refresh_token_families.id'), nullable=False),
        sa.Column('matrix_device_id', sa.String(255), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), nullable=False))


def downgrade():
    raise RuntimeError('Retain expanded mobile session schema and revoked families; use application rollback')
