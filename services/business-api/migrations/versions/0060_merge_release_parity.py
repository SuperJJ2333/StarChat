"""Merge release 2077 and mobile parity migration histories without data changes."""

revision = "0060_merge_release_parity"
down_revision = ("0059_chat_payment_pin", "0041_merge_mobile_parity")
branch_labels = None
depends_on = None


def upgrade() -> None:
    pass


def downgrade() -> None:
    pass
