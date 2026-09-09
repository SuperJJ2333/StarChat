"""Add author-controlled Moments privacy without changing existing preferences."""
from alembic import op
import sqlalchemy as sa

revision = '0058_moments_privacy'
down_revision = '0057_merge_direct_room'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('moments_preferences', sa.Column('profile_entry_enabled', sa.Boolean(), nullable=False, server_default=sa.true()))
    op.add_column('moments_preferences', sa.Column('excluded_user_ids', sa.JSON(), nullable=False, server_default='[]'))


def downgrade():
    raise RuntimeError('Retain Moments privacy columns and settings during application rollback; older applications do not enforce these controls')
