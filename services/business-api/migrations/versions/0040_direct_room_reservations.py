"""Add durable pair creation reservations; preserve every canonical room."""
from alembic import op
import sqlalchemy as sa

revision = '0040_direct_room_reservations'
down_revision = '0039_merge_settings_wallet'
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        'direct_room_reservations',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('user_low_id', sa.String(36), sa.ForeignKey('users.id'), nullable=False),
        sa.Column('user_high_id', sa.String(36), sa.ForeignKey('users.id'), nullable=False),
        sa.Column('owner_id', sa.String(36), sa.ForeignKey('users.id'), nullable=False),
        sa.Column('attempt_id', sa.String(128), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint('user_low_id', 'user_high_id', name='uq_direct_room_reservation_pair'),
    )


def downgrade() -> None:
    # Dropping uncertain reservations could grant duplicate Matrix creation.
    raise RuntimeError('Direct-room reservations require explicit reconciliation before rollback')
