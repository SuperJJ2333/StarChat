"""Add identity, invitation, device, session, RBAC, and security-hold tables."""

from alembic import op
import sqlalchemy as sa

revision = "0004_identity_foundation"
down_revision = "0003_outbox_events"
branch_labels = None
depends_on = None

account_status = sa.Enum(
    "PENDING_EMAIL", "PENDING_MATRIX", "ACTIVE", "SUSPENDED", "DISABLED",
    name="accountstatus",
)
role_code = sa.Enum(
    "USER", "SUPPORT_AGENT", "FINANCE_SUPPORT", "SUPPORT_SUPERVISOR", "SUPER_ADMIN",
    name="rolecode",
)
hold_type = sa.Enum("WITHDRAWAL", name="holdtype")


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("username", sa.String(64), nullable=False),
        sa.Column("username_normalized", sa.String(64), nullable=False, unique=True),
        sa.Column("email", sa.String(320), nullable=False),
        sa.Column("email_normalized", sa.String(320), nullable=False, unique=True),
        sa.Column("password_hash", sa.String(512), nullable=False),
        sa.Column("status", account_status, nullable=False),
        sa.Column("matrix_user_id", sa.String(255), unique=True),
        sa.Column("email_verified_at", sa.DateTime(timezone=True)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_table(
        "invitations",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("code_hash", sa.String(64), nullable=False, unique=True),
        sa.Column("max_uses", sa.Integer(), nullable=False),
        sa.Column("use_count", sa.Integer(), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True)),
        sa.Column("created_by", sa.String(36), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_table(
        "email_verification_challenges",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("token_hash", sa.String(64), nullable=False, unique=True),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("consumed_at", sa.DateTime(timezone=True)),
        sa.Column("attempt_count", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_email_verification_challenges_user_id", "email_verification_challenges", ["user_id"])
    op.create_table(
        "identity_devices",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("device_key", sa.String(128), nullable=False),
        sa.Column("display_name", sa.String(128), nullable=False),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("user_id", "device_key", name="uq_device_user_key"),
    )
    op.create_index("ix_identity_devices_user_id", "identity_devices", ["user_id"])
    op.create_table(
        "refresh_token_families",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("device_id", sa.String(36), sa.ForeignKey("identity_devices.id"), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True)),
        sa.Column("revoke_reason", sa.String(100)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_refresh_token_families_user_id", "refresh_token_families", ["user_id"])
    op.create_table(
        "refresh_tokens",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("family_id", sa.String(36), sa.ForeignKey("refresh_token_families.id"), nullable=False),
        sa.Column("token_hash", sa.String(64), nullable=False, unique=True),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("consumed_at", sa.DateTime(timezone=True)),
        sa.Column("replaced_by_id", sa.String(36)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_refresh_tokens_family_id", "refresh_tokens", ["family_id"])
    op.create_table(
        "user_roles",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("user_id", sa.String(36), nullable=False),
        sa.Column("role_code", role_code, nullable=False),
        sa.Column("assigned_by", sa.String(36), nullable=False),
        sa.Column("assigned_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("user_id", "role_code", name="uq_user_role"),
    )
    op.create_index("ix_user_roles_user_id", "user_roles", ["user_id"])
    op.create_table(
        "totp_credentials",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.id"), nullable=False, unique=True),
        sa.Column("encrypted_secret", sa.String(1024), nullable=False),
        sa.Column("enabled", sa.Boolean(), nullable=False),
        sa.Column("last_accepted_step", sa.Integer()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_table(
        "security_holds",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("hold_type", hold_type, nullable=False),
        sa.Column("reason_code", sa.String(100), nullable=False),
        sa.Column("starts_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ends_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_security_holds_user_id", "security_holds", ["user_id"])


def downgrade() -> None:
    for table, indexes in (
        ("security_holds", ["ix_security_holds_user_id"]),
        ("totp_credentials", []),
        ("user_roles", ["ix_user_roles_user_id"]),
        ("refresh_tokens", ["ix_refresh_tokens_family_id"]),
        ("refresh_token_families", ["ix_refresh_token_families_user_id"]),
        ("identity_devices", ["ix_identity_devices_user_id"]),
        ("email_verification_challenges", ["ix_email_verification_challenges_user_id"]),
        ("invitations", []),
        ("users", []),
    ):
        for index in indexes:
            op.drop_index(index, table_name=table)
        op.drop_table(table)
    hold_type.drop(op.get_bind(), checkfirst=True)
    role_code.drop(op.get_bind(), checkfirst=True)
    account_status.drop(op.get_bind(), checkfirst=True)
