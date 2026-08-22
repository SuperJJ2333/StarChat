"""Track latest friend request time for safe rejected-request reuse."""
from alembic import op
import sqlalchemy as sa

revision = '0020_friend_request_reuse'
down_revision = '0019_matrix_profile_sync'
branch_labels = None
depends_on = None

def upgrade() -> None:
    op.add_column('friend_requests', sa.Column('requested_at', sa.DateTime(timezone=True), nullable=True))
    op.execute('UPDATE friend_requests SET requested_at = created_at WHERE requested_at IS NULL')
    with op.batch_alter_table('friend_requests') as batch:
        batch.alter_column('requested_at', nullable=False)
    op.create_index('ix_friend_requests_pair_status_requested_at', 'friend_requests', ['requester_id', 'target_id', 'status', 'requested_at'])

def downgrade() -> None:
    op.drop_index('ix_friend_requests_pair_status_requested_at', table_name='friend_requests')
    op.drop_column('friend_requests', 'requested_at')
