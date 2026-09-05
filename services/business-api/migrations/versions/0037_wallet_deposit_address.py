"""钱包充值地址与历史分页索引（审计 A01/F07，expand-only，可回滚）。

- wallet_deposit_addresses：充值地址归属持久化（用户+资产唯一地址，
  分配后复用；跨用户隔离）。
- 钱包历史游标分页组合索引：(user_id, created_at, id)——F07 有界检索。
"""
from alembic import op

revision = "0037_wallet_deposit_address"
down_revision = "0036_group_join_tokens"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS wallet_deposit_addresses (
            id VARCHAR(36) PRIMARY KEY,
            user_id VARCHAR(36) NOT NULL,
            asset VARCHAR(20) NOT NULL,
            address VARCHAR(128) NOT NULL,
            created_at TIMESTAMPTZ NOT NULL,
            CONSTRAINT uq_wallet_deposit_address_user_asset UNIQUE (user_id, asset)
        )
        """
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_wallet_deposit_addresses_user"
        " ON wallet_deposit_addresses (user_id)"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_wallet_deposits_history"
        " ON wallet_deposits (user_id, created_at DESC, id DESC)"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_wallet_withdrawals_history"
        " ON wallet_withdrawals (user_id, created_at DESC, id DESC)"
    )


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS ix_wallet_withdrawals_history")
    op.execute("DROP INDEX IF EXISTS ix_wallet_deposits_history")
    op.execute("DROP INDEX IF EXISTS ix_wallet_deposit_addresses_user")
    op.execute("DROP TABLE IF EXISTS wallet_deposit_addresses")
