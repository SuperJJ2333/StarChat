"""Add private drafts and native ad inventory."""
from alembic import op
import sqlalchemy as sa
revision='0025_moment_drafts_native_ads'
down_revision='0024_moment_notifications'
branch_labels=None
depends_on=None
def upgrade():
 op.create_table('moment_drafts',sa.Column('owner_id',sa.String(36),sa.ForeignKey('users.id'),primary_key=True),sa.Column('payload',sa.JSON(),nullable=False),sa.Column('updated_at',sa.DateTime(timezone=True),nullable=False))
 op.create_table('native_moment_ads',sa.Column('id',sa.String(36),primary_key=True),sa.Column('advertiser_name',sa.String(128),nullable=False),sa.Column('avatar_url',sa.String(2048)),sa.Column('text',sa.Text(),nullable=False),sa.Column('image_urls',sa.JSON(),nullable=False),sa.Column('link_url',sa.String(2048),nullable=False),sa.Column('status',sa.String(20),nullable=False),sa.Column('created_at',sa.DateTime(timezone=True),nullable=False))
 op.add_column('moments_preferences',sa.Column('cover_url',sa.String(2048),nullable=True))
def downgrade():
 op.drop_column('moments_preferences','cover_url');op.drop_table('native_moment_ads');op.drop_table('moment_drafts')
