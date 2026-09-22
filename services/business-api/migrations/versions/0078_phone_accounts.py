"""ADR-0075: mainland phone accounts (expand-only).

- users gains nullable phone columns and the findable privacy switch;
- email/email_normalized become nullable (phone channel registers without
  email; fabricating placeholder emails is forbidden);
- the PG accountstatus enum gains PENDING_PHONE (additive);
- otp_challenges stores hashed, purpose-bound, single-consume codes.

SQLite lacks ALTER support for some of these; batch mode recreates safely.
"""
from alembic import op
import sqlalchemy as sa

revision = "0078_phone_accounts"
down_revision = "0077_recharge_requests"
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table("users") as batch:
        batch.add_column(sa.Column("phone", sa.String(length=20), nullable=True))
        batch.add_column(sa.Column("phone_normalized", sa.String(length=20), nullable=True))
        batch.create_index("uq_users_phone_normalized", ["phone_normalized"], unique=True,
            sqlite_where=sa.text("phone_normalized IS NOT NULL"),
            postgresql_where=sa.text("phone_normalized IS NOT NULL"))
        batch.add_column(sa.Column("phone_verified_at", sa.DateTime(timezone=True), nullable=True))
        batch.add_column(sa.Column("phone_findable", sa.Boolean(), nullable=False, server_default=sa.true()))
        batch.alter_column("email", existing_type=sa.String(length=320), nullable=True)
        batch.alter_column("email_normalized", existing_type=sa.String(length=320), nullable=True)
    op.execute("ALTER TYPE accountstatus ADD VALUE IF NOT EXISTS 'PENDING_PHONE'")
    op.create_table(
        "otp_challenges",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("purpose", sa.String(length=24), nullable=False, index=True),
        sa.Column("target", sa.String(length=320), nullable=False, index=True),
        sa.Column("user_id", sa.String(length=36), nullable=True, index=True),
        sa.Column("registration_session", sa.String(length=64), nullable=True),
        sa.Column("code_hash", sa.String(length=64), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("attempts_left", sa.Integer(), nullable=False, server_default="5"),
        sa.Column("consumed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("invalidated_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )


def downgrade():
    op.drop_table("otp_challenges")
    # PG enum value removal is not supported; PENDING_PHONE stays unused.
    with op.batch_alter_table("users") as batch:
        batch.drop_column("phone_findable")
        batch.drop_column("phone_verified_at")
        batch.drop_index("uq_users_phone_normalized")
        batch.drop_column("phone_normalized")
        batch.drop_column("phone")
