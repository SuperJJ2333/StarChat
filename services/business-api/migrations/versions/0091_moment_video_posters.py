"""Expand-only optional video posters and publication request identity.

Existing Moment rows retain NULL; old clients and old no-poster videos remain
compatible. Application rollback retains these optional columns and their data.
"""
from alembic import op
import sqlalchemy as sa

revision = '0091_moment_video_posters'
down_revision = '0090_friend_discovery_index'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('moments', sa.Column('video_poster_keys', sa.JSON(), nullable=True))
    op.add_column('moments', sa.Column('request_fingerprint', sa.String(length=64), nullable=True))


def downgrade():
    # Retain optional columns on application rollback; never drop media refs.
    pass
