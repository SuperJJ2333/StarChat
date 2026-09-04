"""群聊加入令牌与审批（群二维码进群，expand-only，可回滚）。

group_join_tokens：群二维码安全令牌。库存 sha256(token)（明文令牌只在
签发响应中出现一次，绝不入库/入日志）；默认 7 天过期；可撤销（轮换=
撤销旧+签发新）。
group_join_requests：扫码加入且群开启审批时的入群申请。
"""
from alembic import op

revision = "0036_group_join_tokens"
down_revision = "0035_direct_conversations"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS group_join_tokens (
            id VARCHAR(36) PRIMARY KEY,
            room_id VARCHAR(255) NOT NULL,
            creator_user_id VARCHAR(36) NOT NULL REFERENCES users(id),
            token_hash VARCHAR(64) NOT NULL,
            created_at TIMESTAMPTZ NOT NULL,
            expires_at TIMESTAMPTZ NOT NULL,
            revoked_at TIMESTAMPTZ
        )
        """
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_group_join_tokens_hash"
        " ON group_join_tokens (token_hash)"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_group_join_tokens_room"
        " ON group_join_tokens (room_id)"
    )
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS group_join_requests (
            id VARCHAR(36) PRIMARY KEY,
            room_id VARCHAR(255) NOT NULL,
            requester_user_id VARCHAR(36) NOT NULL REFERENCES users(id),
            token_id VARCHAR(36) REFERENCES group_join_tokens(id),
            status VARCHAR(20) NOT NULL,
            created_at TIMESTAMPTZ NOT NULL,
            decided_at TIMESTAMPTZ,
            decider_user_id VARCHAR(36) REFERENCES users(id)
        )
        """
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_group_join_requests_room"
        " ON group_join_requests (room_id, status)"
    )
    # 活跃申请幂等：同一用户在同一房间至多一条 pending（部分索引，
    # PostgreSQL 支持；SQLite 测试库由模型层唯一约束兜底）。
    op.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS uq_group_join_request_pending"
        " ON group_join_requests (room_id, requester_user_id)"
        " WHERE status = 'PENDING'"
    )


def downgrade() -> None:
    op.execute("DROP TABLE IF EXISTS group_join_requests")
    op.execute("DROP TABLE IF EXISTS group_join_tokens")
