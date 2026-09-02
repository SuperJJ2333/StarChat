"""Add custody webhook deduplication records."""
from alembic import op
import sqlalchemy as sa
revision="0011_wallet_webhook_events"
down_revision="0010_usdt_wallet"
branch_labels=None
depends_on=None

def upgrade():
    op.create_table("wallet_webhook_events", sa.Column("event_id", sa.String(128), primary_key=True), sa.Column("event_type", sa.String(64), nullable=False), sa.Column("received_at", sa.DateTime(timezone=True), nullable=False))

def downgrade(): op.drop_table("wallet_webhook_events")
