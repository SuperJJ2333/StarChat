"""Bind management sessions to the verified login entry point.

Existing rows remain NULL and require a fresh login. A former staff session
cannot be inferred to have passed the administrator CAPTCHA.
"""
from alembic import op
import sqlalchemy as sa

revision = '0092_admin_session_entry_mode'
down_revision = '0091_moment_video_posters'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('identity_admin_sessions', sa.Column('entry_mode', sa.String(length=16), nullable=True))
    op.create_check_constraint('ck_identity_admin_sessions_entry_mode',
        'identity_admin_sessions', "entry_mode IN ('STAFF', 'ADMIN')")


def downgrade():
    # A legacy API must not read an ADMIN default for an unverified staff entry.
    raise RuntimeError('entry_mode is retained on application rollback')
