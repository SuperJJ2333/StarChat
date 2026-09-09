"""Expand identity with independent six-digit payment credentials and intents."""
from alembic import op
import sqlalchemy as sa

revision = '0059_chat_payment_pin'
down_revision = '0058_moments_privacy'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table('payment_pin_credentials',
        sa.Column('user_id', sa.String(36), sa.ForeignKey('users.id'), primary_key=True),
        sa.Column('pin_hash', sa.String(512), nullable=False),
        sa.Column('version', sa.Integer(), nullable=False),
        sa.Column('failed_attempts', sa.Integer(), nullable=False),
        sa.Column('locked_until', sa.DateTime(timezone=True)),
        sa.Column('setup_key_hash', sa.String(64), nullable=False),
        sa.Column('setup_family_id', sa.String(36), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False))
    op.create_table('payment_pin_authorizations',
        sa.Column('token_hash', sa.String(64), primary_key=True),
        sa.Column('user_id', sa.String(36), sa.ForeignKey('users.id'), nullable=False),
        sa.Column('family_id', sa.String(36), nullable=False),
        sa.Column('credential_version', sa.Integer(), nullable=False),
        sa.Column('intent_hash', sa.String(64), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('expires_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('consumed_at', sa.DateTime(timezone=True)))
    op.create_index('ix_payment_pin_authorizations_user_id', 'payment_pin_authorizations', ['user_id'])
    op.create_index('ix_payment_pin_authorizations_expires_at', 'payment_pin_authorizations', ['expires_at'])


def downgrade():
    raise RuntimeError('Retain payment PIN credentials and authorizations; rollback must preserve payment enforcement')
