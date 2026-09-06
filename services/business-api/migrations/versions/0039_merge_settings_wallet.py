"""Merge independently deployable settings and wallet branches (no DDL)."""

revision = "0039_merge_settings_wallet"
down_revision = ("0037_wallet_deposit_address", "0038_app_settings_text")
branch_labels = None
depends_on = None


def upgrade() -> None:
    pass


def downgrade() -> None:
    pass
