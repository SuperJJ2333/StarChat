"""Join published refresh recovery and phone/wallet expansion histories.

Both branches remain intact. This revision performs no data rewrite.
"""

revision = '0083_phone_wallet_refresh_merge'
down_revision = ('0080_refresh_recovery', '0082_deposit_intent_cancel')
branch_labels = None
depends_on = None


def upgrade():
    pass


def downgrade():
    raise RuntimeError('Preserve both published histories; use a forward migration')
