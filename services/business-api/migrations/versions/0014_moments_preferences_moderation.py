"""Moments preferences and reports."""
from alembic import op
import sqlalchemy as sa
revision='0014_moments_preferences_moderation';down_revision='0013_moments';branch_labels=None;depends_on=None
def upgrade():
    op.create_table('moments_preferences',sa.Column('user_id',sa.String(36),sa.ForeignKey('users.id'),primary_key=True),sa.Column('history_range',sa.String(20),nullable=False),sa.Column('personalized_recommendations',sa.Boolean(),nullable=False),sa.Column('cover_url',sa.String(2048)),sa.Column('updated_at',sa.DateTime(timezone=True),nullable=False))
    op.create_table('moment_reports',sa.Column('id',sa.String(36),primary_key=True),sa.Column('moment_id',sa.String(36),sa.ForeignKey('moments.id'),nullable=False),sa.Column('reporter_id',sa.String(36),sa.ForeignKey('users.id'),nullable=False),sa.Column('reason_code',sa.String(100),nullable=False),sa.Column('idempotency_key',sa.String(128),nullable=False),sa.Column('status',sa.String(20),nullable=False),sa.Column('created_at',sa.DateTime(timezone=True),nullable=False),sa.UniqueConstraint('reporter_id','idempotency_key',name='uq_moment_report_idempotency'))
def downgrade():op.drop_table('moment_reports');op.drop_table('moments_preferences')
