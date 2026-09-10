"""Expand wallet access state independently of mobile release migrations."""
from alembic import op
import sqlalchemy as sa

revision = '0062_wallet_access_grant'
down_revision = '0059_chat_payment_pin'
branch_labels = ('wallet_access',)
depends_on = None


def upgrade():
    op.create_table('identity_wallet_access_grants',
        sa.Column('family_id', sa.String(36), primary_key=True),
        sa.Column('grant_id', sa.String(36), nullable=False, unique=True),
        sa.Column('user_id', sa.String(36), nullable=False),
        sa.Column('device_id', sa.String(36), nullable=False),
        sa.Column('scope', sa.String(32), nullable=False),
        sa.Column('auth_mode', sa.String(32), nullable=False),
        sa.Column('configuration_digest', sa.String(64), nullable=False),
        sa.Column('credential_digest', sa.String(64), nullable=False),
        sa.Column('verified_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('expires_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('revoked_at', sa.DateTime(timezone=True)),
        sa.CheckConstraint('expires_at > verified_at', name='ck_wallet_grant_deadline'))
    op.create_index('ix_identity_wallet_access_grants_user_id', 'identity_wallet_access_grants', ['user_id'])
    op.create_table('identity_wallet_access_attempts',
        sa.Column('user_id', sa.String(36), primary_key=True),
        sa.Column('attempt_count', sa.Integer(), nullable=False),
        sa.Column('window_started_at', sa.DateTime(timezone=True), nullable=False))


def downgrade():
    raise RuntimeError('Disable wallet_access_grant_enabled and retain revocations; use application rollback')
