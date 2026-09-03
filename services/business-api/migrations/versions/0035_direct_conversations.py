"""Canonical Direct Conversation 登记表（好友系统重构 Phase E，expand-only）。

direct_conversations：每对好友至多一条规范私聊房间记录
（UNIQUE(user_low_id, user_high_id)）。创建私聊前客户端先查询复用；
不存在时客户端创建 Matrix Direct Chat 后注册；并发双开冲突返回既有行。
"""
from alembic import op

revision = "0035_direct_conversations"
down_revision = "0034_referral_bindings"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS direct_conversations (
            id VARCHAR(36) PRIMARY KEY,
            user_low_id VARCHAR(36) NOT NULL REFERENCES users(id),
            user_high_id VARCHAR(36) NOT NULL REFERENCES users(id),
            matrix_room_id VARCHAR(255) NOT NULL,
            created_at TIMESTAMPTZ NOT NULL
        )
        """
    )
    op.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS uq_direct_conversation_pair"
        " ON direct_conversations (user_low_id, user_high_id)"
    )


def downgrade() -> None:
    op.execute("DROP TABLE IF EXISTS direct_conversations")
