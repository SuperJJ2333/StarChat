"""Moment media upload sessions."""
from alembic import op
import sqlalchemy as sa
revision='0016_moment_media';down_revision='0015_contact_tags';branch_labels=None;depends_on=None
def upgrade():
    op.create_table('moment_media_uploads',sa.Column('id',sa.String(36),primary_key=True),sa.Column('owner_id',sa.String(36),sa.ForeignKey('users.id'),nullable=False),sa.Column('file_name',sa.String(255),nullable=False),sa.Column('mime_type',sa.String(100),nullable=False),sa.Column('byte_size',sa.Integer(),nullable=False),sa.Column('status',sa.String(20),nullable=False),sa.Column('object_key',sa.String(512),nullable=False,unique=True),sa.Column('idempotency_key',sa.String(128),nullable=False),sa.Column('created_at',sa.DateTime(timezone=True),nullable=False),sa.Column('expires_at',sa.DateTime(timezone=True),nullable=False),sa.UniqueConstraint('owner_id','idempotency_key',name='uq_moment_media_upload_idempotency'))
    op.create_index('ix_moment_media_uploads_owner_id','moment_media_uploads',['owner_id']);op.create_index('ix_moment_media_uploads_status','moment_media_uploads',['status'])
def downgrade():op.drop_index('ix_moment_media_uploads_status',table_name='moment_media_uploads');op.drop_index('ix_moment_media_uploads_owner_id',table_name='moment_media_uploads');op.drop_table('moment_media_uploads')
