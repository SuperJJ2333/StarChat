"""补齐 friend_requests 的申请人联系人偏好列（幂等修补，expand-only）。"""
from alembic import op

revision = "0032_friend_request_prefs"
down_revision = "0031_friend_request_requested_at"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        DO $$
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name = 'friend_requests'
                  AND column_name = 'contact_remark'
            ) THEN
                ALTER TABLE friend_requests
                    ADD COLUMN contact_remark VARCHAR(64);
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name = 'friend_requests'
                  AND column_name = 'contact_tags'
            ) THEN
                ALTER TABLE friend_requests
                    ADD COLUMN contact_tags TEXT DEFAULT '';
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name = 'friend_requests'
                  AND column_name = 'contact_moments_permission'
            ) THEN
                ALTER TABLE friend_requests
                    ADD COLUMN contact_moments_permission VARCHAR(30) DEFAULT 'DEFAULT';
            END IF;
        END
        $$;
        """
    )


def downgrade() -> None:
    pass
