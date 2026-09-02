"""补齐 complaints 投诉表（expand-only，幂等）。"""
from alembic import op
import sqlalchemy as sa

revision = "0033_complaints"
down_revision = "0032_friend_request_prefs"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        DO $$
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.tables
                WHERE table_name = 'complaints'
            ) THEN
                CREATE TABLE complaints (
                    id VARCHAR(36) PRIMARY KEY,
                    user_id VARCHAR(36) NOT NULL REFERENCES users(id),
                    category VARCHAR(30) NOT NULL,
                    description TEXT NOT NULL,
                    created_at TIMESTAMPTZ NOT NULL
                );
                CREATE INDEX ix_complaints_user_id ON complaints (user_id);
                CREATE INDEX ix_complaints_created_at ON complaints (created_at);
            END IF;
        END
        $$;
        """
    )


def downgrade() -> None:
    pass
