"""Expand-only verified direct conversation source-room metadata."""
from alembic import op
import sqlalchemy as sa

revision = '0070_direct_room_history'
down_revision = '0069_media_platform'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table('direct_conversation_rooms',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('user_low_id', sa.String(36), sa.ForeignKey('users.id'), nullable=False),
        sa.Column('user_high_id', sa.String(36), sa.ForeignKey('users.id'), nullable=False),
        sa.Column('matrix_room_id', sa.String(255), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint('user_low_id', 'user_high_id', 'matrix_room_id', name='uq_direct_conversation_source'))


def downgrade():
    # App rollback leaves the additive table and verified history intact.
    pass
