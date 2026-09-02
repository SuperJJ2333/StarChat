"""点钻账本并发扣减验证（在业务 API 容器内、连临时隔离 Postgres 执行）。

场景：账户余额 10.00 点钻，16 个线程各自并发扣 1.00。
- 修复后预期：恰好 10 笔成功、6 笔余额不足、最终余额 0.00、无负余额。
- 修复前（无锁）：多个事务读到同一余额后同时提交，成功笔数 > 10 或出现负余额。
"""
import os
import sys
import threading

sys.path.insert(0, "/opt/business-api")

from sqlalchemy import create_engine, text

PG_URL = os.environ["VERIFY_PG_URL"]

engine = create_engine(PG_URL, pool_size=8, max_overflow=16, pool_pre_ping=True)
from app.core.database import Base, create_session_factory
import app.modules.ledger.service  # noqa: F401 - 先注册 ORM 模型再建表
from app.modules.ledger.service import LedgerService
Base.metadata.create_all(engine)

factory = create_session_factory(engine)
ledger = LedgerService(factory)

ACCOUNT = "concurrent-verify-account"
# 初始余额 10.00 点钻（平台对手方入账）
ledger.post(
    entries={ACCOUNT: __import__("decimal").Decimal("10.00"), "PLATFORM_CLEARING": __import__("decimal").Decimal("-10.00")},
    actor_id="verify", reason_code="VERIFY_SEED", idempotency_key="verify-seed", scope="verify",
)

results = {"ok": 0, "insufficient": 0, "error": 0}
lock = threading.Lock()

def withdraw(i):
    try:
        ledger.post(
            entries={ACCOUNT: __import__("decimal").Decimal("-1.00"), "PLATFORM_CLEARING": __import__("decimal").Decimal("1.00")},
            actor_id="verify", reason_code="VERIFY_WITHDRAW", idempotency_key=f"verify-wd-{i}", scope="verify",
        )
        with lock: results["ok"] += 1
    except ValueError as e:
        if "insufficient" in str(e):
            with lock: results["insufficient"] += 1
        else:
            with lock: results["error"] += 1
            print("VALUE_ERROR", e)
    except Exception as e:
        with lock: results["error"] += 1
        print("ERROR", type(e).__name__, str(e)[:120])

threads = [threading.Thread(target=withdraw, args=(i,)) for i in range(16)]
for t in threads: t.start()
for t in threads: t.join()

balance = ledger.balance(ACCOUNT)
print(f"OK={results['ok']} INSUFFICIENT={results['insufficient']} ERROR={results['error']} FINAL_BALANCE={balance}")
passed = results["ok"] == 10 and results["insufficient"] == 6 and results["error"] == 0 and str(balance) == "0.00"
print("CONCURRENCY_VERIFY", "PASS" if passed else "FAIL")
sys.exit(0 if passed else 1)
