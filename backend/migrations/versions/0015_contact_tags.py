"""Contact tags."""
from alembic import op
import sqlalchemy as sa
revision='0015_contact_tags';down_revision='0014_moments_prefs';branch_labels=None;depends_on=None
def upgrade():
    op.create_table('contact_tags',sa.Column('id',sa.String(36),primary_key=True),sa.Column('owner_id',sa.String(36),sa.ForeignKey('users.id'),nullable=False),sa.Column('name',sa.String(64),nullable=False),sa.Column('created_at',sa.DateTime(timezone=True),nullable=False),sa.UniqueConstraint('owner_id','name',name='uq_contact_tag_owner_name'))
    op.create_index('ix_contact_tags_owner_id','contact_tags',['owner_id'])
def downgrade():
    op.drop_index('ix_contact_tags_owner_id',table_name='contact_tags');op.drop_table('contact_tags')
