"""账本账户的事务级并发锁。

余额采用"条目聚合"模型（无独立余额行可 FOR UPDATE），并发扣减会同时读到
相同余额、双双通过校验后提交，造成超扣/双花。这里用 PostgreSQL 事务级
advisory lock 对被扣减账户串行化：同一账户的扣减事务彼此排队，
锁随事务结束自动释放；SQLite（单写者）天然串行，直接跳过。
"""
from sqlalchemy import text


def lock_accounts(session, accounts: list[str], *, asset: str) -> None:
    """对本次事务要扣减的账户按排序获取 advisory xact lock（防死锁）。

    非 PostgreSQL 方言（单元测试用的 SQLite 内存库）不做任何操作。
    """
    if session.get_bind().dialect.name != "postgresql":
        return
    for account in sorted(set(accounts)):
        session.execute(
            text("SELECT pg_advisory_xact_lock(hashtext(:key))"),
            {"key": f"ledger:{asset}:{account}"},
        )
