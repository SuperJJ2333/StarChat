"""referral 邀请关系表（expand-only，幂等）。

referral_invites：当前窗口码发布表（每用户一行，唯一 code_hash 反查邀请人）；
referral_bindings：好友注册时形成的邀请关系（每名新用户至多一条）。
"""
from alembic import op

revision = "0034_referral_bindings"
down_revision = "0033_complaints"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS referral_invites (
            user_id VARCHAR(36) PRIMARY KEY REFERENCES users(id),
            code_hash VARCHAR(64) NOT NULL,
            window_index BIGINT NOT NULL,
            updated_at TIMESTAMPTZ NOT NULL
        )
        """
    )
    op.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS uq_referral_invites_code_hash"
        " ON referral_invites (code_hash)"
    )
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS referral_bindings (
            id VARCHAR(36) PRIMARY KEY,
            inviter_user_id VARCHAR(36) NOT NULL REFERENCES users(id),
            invited_user_id VARCHAR(36) NOT NULL UNIQUE REFERENCES users(id),
            code_hash VARCHAR(64) NOT NULL,
            code_window_index BIGINT NOT NULL,
            status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
            reward_state VARCHAR(30) NOT NULL DEFAULT 'NOT_CONFIGURED',
            bound_at TIMESTAMPTZ NOT NULL,
            created_at TIMESTAMPTZ NOT NULL
        )
        """
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_referral_bindings_inviter_user_id"
        " ON referral_bindings (inviter_user_id)"
    )


def downgrade() -> None:
    pass
