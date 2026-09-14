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

## 备注（同日补充：EXPECTED_HEAD 同源缺陷）

CI run #94 确认 Infra render tests 转绿后，backend job 暴露同源的第二个缺口：`628be215` 同时更新了 `tests/business_api/test_wallet_release_baseline.py::test_release_preflight_pins_the_integrated_migration_head`（要求 `EXPECTED_HEAD == '0066_manual_deposit_cases'`）却未改脚本（仍为 0064）。本地全量复现仅此 1 项失败（1910 passed）。已将 `scripts/wallet_release_preflight.py` 的 `EXPECTED_HEAD` 提升为 `0066_manual_deposit_cases`（与 `alembic heads` 单头一致）；`test_wallet_release_baseline.py` + `test_wallet_release_preflight.py` 共 37 passed。

CI run #94 其余状态：Infra render tests ✅（本记录第一项修复生效）、Flutter job 全绿（钱包 29 项基线已由其任务清零，Analyze ✅ Test ✅）、Debug APK ✅。
