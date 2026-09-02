"""Add notice receipts and native ad campaign delivery state."""
from alembic import op
import sqlalchemy as sa

revision = "0028_notice_receipts_ads"
down_revision = "0027_admin_controls"
branch_labels = None
depends_on = None

def upgrade() -> None:
    op.create_table("notice_receipts", sa.Column("id", sa.String(36), primary_key=True), sa.Column("notice_id", sa.String(36), nullable=False), sa.Column("user_id", sa.String(36), nullable=False), sa.Column("read_at", sa.DateTime(timezone=True), nullable=False), sa.Column("idempotency_key", sa.String(128), nullable=False), sa.UniqueConstraint("notice_id", "user_id", name="uq_notice_receipt_user"))
    op.create_index("ix_notice_receipts_notice_id", "notice_receipts", ["notice_id"])
    op.create_index("ix_notice_receipts_user_id", "notice_receipts", ["user_id"])
    op.create_table("native_ad_campaigns", sa.Column("id", sa.String(36), primary_key=True), sa.Column("ad_id", sa.String(36), nullable=False), sa.Column("starts_at", sa.DateTime(timezone=True), nullable=False), sa.Column("ends_at", sa.DateTime(timezone=True), nullable=False), sa.Column("audience", sa.JSON(), nullable=False), sa.Column("status", sa.String(20), nullable=False), sa.Column("impressions", sa.Integer(), nullable=False, server_default="0"), sa.Column("clicks", sa.Integer(), nullable=False, server_default="0"), sa.Column("created_by", sa.String(36), nullable=False), sa.Column("created_at", sa.DateTime(timezone=True), nullable=False), sa.UniqueConstraint("ad_id", name="uq_native_ad_campaign_ad"))
    op.create_index("ix_native_ad_campaigns_ad_id", "native_ad_campaigns", ["ad_id"])

def downgrade() -> None:
    op.drop_index("ix_native_ad_campaigns_ad_id", table_name="native_ad_campaigns"); op.drop_table("native_ad_campaigns")
    op.drop_index("ix_notice_receipts_user_id", table_name="notice_receipts"); op.drop_index("ix_notice_receipts_notice_id", table_name="notice_receipts"); op.drop_table("notice_receipts")
