"""Default-enable user-controlled server auto-join for Matrix groups."""
from alembic import op
import sqlalchemy as sa

revision = '0021_group_auto_join'
down_revision = '0020_friend_request_reuse'
branch_labels = None
depends_on = None

def upgrade() -> None:
    op.add_column('users', sa.Column('auto_allow_group_join', sa.Boolean(), nullable=False, server_default=sa.true()))

def downgrade() -> None:
    op.drop_column('users', 'auto_allow_group_join')

