"""Expand settings values without changing API length limits.

Application rollback can retain TEXT. Narrowing refuses long values; it never
silently truncates release notes or download URLs.
"""
from alembic import op

revision = "0038_app_settings_text"
down_revision = "0036_group_join_tokens"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE app_settings ALTER COLUMN value TYPE TEXT")


def downgrade() -> None:
    # Lock before checking so a concurrent writer cannot introduce a long value
    # between validation and PostgreSQL's otherwise truncating explicit cast.
    op.execute("LOCK TABLE app_settings IN ACCESS EXCLUSIVE MODE")
    op.execute("""
        DO $$ BEGIN
            IF EXISTS (SELECT 1 FROM app_settings WHERE char_length(value) > 255) THEN
                RAISE EXCEPTION 'Cannot narrow app_settings.value: values exceed 255 characters; retain TEXT for application rollback';
            END IF;
        END $$
    """)
    op.execute("ALTER TABLE app_settings ALTER COLUMN value TYPE VARCHAR(255)")
