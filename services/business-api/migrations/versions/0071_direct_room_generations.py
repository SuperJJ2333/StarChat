"""Expand-only durable direct conversation recovery generations."""
from alembic import op
import sqlalchemy as sa

revision = '0071_direct_room_generations'
down_revision = '0070_direct_room_history'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table('direct_pair_mutexes',
        sa.Column('user_low_id', sa.String(36), sa.ForeignKey('users.id'), primary_key=True),
        sa.Column('user_high_id', sa.String(36), sa.ForeignKey('users.id'), primary_key=True))
    op.add_column('direct_conversations', sa.Column('revision', sa.Integer(), nullable=False, server_default='0'))
    op.create_table('direct_room_generations',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('user_low_id', sa.String(36), sa.ForeignKey('users.id'), nullable=False),
        sa.Column('user_high_id', sa.String(36), sa.ForeignKey('users.id'), nullable=False),
        sa.Column('generation', sa.Integer(), nullable=False),
        sa.Column('expected_old_room_id', sa.String(255), nullable=False),
        sa.Column('recovery_reason', sa.String(30), nullable=False, server_default='retired'),
        sa.Column('departed_user_id', sa.String(36), sa.ForeignKey('users.id')),
        sa.Column('matrix_room_id', sa.String(255)),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint('user_low_id', 'user_high_id', 'generation', name='uq_direct_room_generation'))


def downgrade():
    # Keep aliases and publication fences during application rollback.
    pass
