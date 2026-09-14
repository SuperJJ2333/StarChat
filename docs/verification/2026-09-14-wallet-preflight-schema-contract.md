# 2026-09-14 钱包发布预检 schema 契约补齐

## 缺陷

`628be215`（feat: land support identity, manual deposit cases and wallet conversion streams）新增 `wallet_manual_deposit_cases` / `wallet_manual_deposit_decisions` 两表，并给 `tests/infra/test_wallet_release_preflight.py::test_manual_release_requires_new_schema` 的参数化列表加了这两张表（要求 DROP 后预检必须返回 SCHEMA_INCOMPLETE），但未同步 `scripts/wallet_release_preflight.py` 的 `REQUIRED_COLUMNS`——预检对这两张表不设防，release 门会放行缺表的库。6 个参数化用例中 2 个失败。

## 修复

按 `app/modules/wallet/repair_models.py` 的真实列定义，在 `REQUIRED_COLUMNS` 增补（子集语义，与既有条目风格一致）：

- `wallet_manual_deposit_cases`: id receipt_id user_id binding_id binding_version facts_digest actor_id idempotency_key payload_digest created_at
- `wallet_manual_deposit_decisions`: id case_id actor_id decision idempotency_key payload_digest created_at

## 验证（Windows / .venv）

- 修复前红：`pytest "tests/infra/test_wallet_release_preflight.py::test_manual_release_requires_new_schema" -q` → 2 failed（正是两张 deposit 表）/ 4 passed。
- 修复后绿：该文件 35 passed；全量 `pytest tests/infra -q` → **143 passed**。

## 备注（不在本缺陷范围）

`alembic heads` = `0066_manual_deposit_cases`（单头），而预检 `EXPECTED_HEAD = '0064_admin_deposit_repairs'` 落后两个修订。测试 fixture 用 EXPECTED_HEAD 自盖 alembic_version 故不受影响，但对真实库执行预检会报 MIGRATION_HEAD_MISMATCH。是否随发布提升 EXPECTED_HEAD 属发布门策略，归发布任务决策。
