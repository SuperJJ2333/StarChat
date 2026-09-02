"""Add private moment interaction notifications."""
from alembic import op
import sqlalchemy as sa
revision='0024_moment_notifications'
down_revision='0023_moments_social_completion'
branch_labels=None
depends_on=None
def upgrade():
 op.create_table('moment_notifications',sa.Column('id',sa.String(36),primary_key=True),sa.Column('recipient_id',sa.String(36),sa.ForeignKey('users.id'),nullable=False),sa.Column('moment_id',sa.String(36),sa.ForeignKey('moments.id'),nullable=False),sa.Column('actor_id',sa.String(36),sa.ForeignKey('users.id'),nullable=False),sa.Column('kind',sa.String(20),nullable=False),sa.Column('comment_id',sa.String(36)),sa.Column('read_at',sa.DateTime(timezone=True)),sa.Column('invalidated_at',sa.DateTime(timezone=True)),sa.Column('created_at',sa.DateTime(timezone=True),nullable=False),sa.UniqueConstraint('recipient_id','kind','moment_id','actor_id','comment_id',name='uq_moment_notification'))
def downgrade(): op.drop_table('moment_notifications')
