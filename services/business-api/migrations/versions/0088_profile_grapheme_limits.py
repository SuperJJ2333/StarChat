"""Widen profile text storage for extended grapheme clusters."""

from alembic import op
import sqlalchemy as sa


revision = "0088_profile_grapheme_limits"
down_revision = "0087_support_payout_workflow"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.alter_column(
        "users", "nickname",
        existing_type=sa.String(64), type_=sa.Text(), existing_nullable=False,
    )
    op.alter_column(
        "users", "signature",
        existing_type=sa.String(140), type_=sa.Text(), existing_nullable=True,
    )


def downgrade() -> None:
    connection = op.get_bind()
    overlong = connection.scalar(sa.text(
        "SELECT EXISTS (SELECT 1 FROM users "
        "WHERE char_length(nickname) > 64 OR char_length(signature) > 140)"
    ))
    if overlong:
        raise RuntimeError("Cannot narrow profile columns without truncating saved values")
    op.alter_column(
        "users", "signature",
        existing_type=sa.Text(), type_=sa.String(140), existing_nullable=True,
    )
    op.alter_column(
        "users", "nickname",
        existing_type=sa.Text(), type_=sa.String(64), existing_nullable=False,
    )
