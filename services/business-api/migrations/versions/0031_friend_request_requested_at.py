"""补齐 0020 未落库的 friend_requests.requested_at（幂等修补）。

部分环境的历史库存在版本号已推进到 0030 但 0020 增量未真正落库的情况
（friend_requests 缺 requested_at 列与复合索引）。本迁移按幂等条件补齐，
不触碰其他结构；downgrade 为 no-op —— 结构契约属 0020，回滚由
0020.downgrade 定义。
"""
from alembic import op

revision = "0031_friend_request_requested_at"
down_revision = "0030_app_settings"
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
                  AND column_name = 'requested_at'
            ) THEN
                ALTER TABLE friend_requests ADD COLUMN requested_at TIMESTAMPTZ;
                UPDATE friend_requests
                   SET requested_at = created_at
                 WHERE requested_at IS NULL;
                ALTER TABLE friend_requests
                      ALTER COLUMN requested_at SET NOT NULL;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM pg_indexes
                WHERE tablename = 'friend_requests'
                  AND indexname = 'ix_friend_requests_pair_status_requested_at'
            ) THEN
                CREATE INDEX ix_friend_requests_pair_status_requested_at
                    ON friend_requests (requester_id, target_id, status, requested_at);
            END IF;
        END
        $$;
        """
    )


def downgrade() -> None:
    # 修补型迁移：补齐的是 0020 的契约结构，回滚由 0020.downgrade 承担。
    pass
