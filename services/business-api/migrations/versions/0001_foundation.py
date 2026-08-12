"""Establish the initial migration boundary for 六合通 business data."""

revision = "0001_foundation"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Domain tables are introduced by later, independently auditable revisions.
    pass


def downgrade() -> None:
    pass
