"""Expand registration verification and user profile persistence."""

from alembic import op
import sqlalchemy as sa


revision = "0017_registration_profile"
down_revision = "0016_moment_media"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("users", sa.Column("nickname", sa.String(64), nullable=True))
    op.add_column("users", sa.Column("signature", sa.String(140), nullable=True))
    op.add_column("users", sa.Column("avatar_object_key", sa.String(512), nullable=True))
    op.add_column(
        "users",
        sa.Column("profile_updated_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.execute("UPDATE users SET nickname = username, profile_updated_at = created_at")
    op.alter_column("users", "nickname", existing_type=sa.String(64), nullable=False)
    op.alter_column(
        "users",
        "profile_updated_at",
        existing_type=sa.DateTime(timezone=True),
        nullable=False,
    )

    op.add_column(
        "email_verification_challenges",
        sa.Column("registration_session_hash", sa.String(64), nullable=True),
    )
    op.add_column(
        "email_verification_challenges",
        sa.Column("code_hash", sa.String(64), nullable=True),
    )
    op.add_column(
        "email_verification_challenges",
        sa.Column("link_token_hash", sa.String(64), nullable=True),
    )
    op.add_column(
        "email_verification_challenges",
        sa.Column("resend_available_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "email_verification_challenges",
        sa.Column("invalidated_at", sa.DateTime(timezone=True), nullable=True),
    )
    active_predicate = sa.text("consumed_at IS NULL AND invalidated_at IS NULL")
    op.create_index(
        "uq_email_verification_registration_session_hash",
        "email_verification_challenges",
        ["registration_session_hash"],
        unique=True,
        postgresql_where=active_predicate,
    )
    op.create_index(
        "ix_email_verification_active_challenge",
        "email_verification_challenges",
        ["user_id", "expires_at"],
        postgresql_where=active_predicate,
    )


def downgrade() -> None:
    op.drop_index(
        "ix_email_verification_active_challenge",
        table_name="email_verification_challenges",
    )
    op.drop_index(
        "uq_email_verification_registration_session_hash",
        table_name="email_verification_challenges",
    )
    for column_name in (
        "invalidated_at",
        "resend_available_at",
        "link_token_hash",
        "code_hash",
        "registration_session_hash",
    ):
        op.drop_column("email_verification_challenges", column_name)

    for column_name in (
        "profile_updated_at",
        "avatar_object_key",
        "signature",
        "nickname",
    ):
        op.drop_column("users", column_name)
