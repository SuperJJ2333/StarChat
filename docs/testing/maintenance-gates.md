# 按模块执行的条件门禁

状态：Current。基线为 2026-10-23 合并维护门禁的 148 项跳过；它们不是 148 项失败，也不表示设置一个开关即可全部执行。[开发环境](../runbooks/agent-maintenance.md) · [本轮结果](../verification/2026-10-23-maintenance-environment.md)。

## 选择与计数

先运行对应模块的普通单元/契约测试；修改金融、认证、Outbox/Worker、并发锁或迁移时，还必须运行下表对应真实 PostgreSQL 场景。跨模块修改取并集，保留现有审查要求。

原 148 项中：144 项因 PostgreSQL 配置缺失跳过，3 项为 SQLite 参数变体不适用的锁/进程/序列化检查，1 项缺 Ruby。配置数据库还会增加原本未收集的 PG 参数变体，不能用原总数减去通过数推算覆盖。合格证据需同时记录 nodeid、参数、通过/失败/跳过理由和数据库版本。

| 触发模块 | 测试文件（从仓库根执行） | 历史跳过 | 显式环境条件 | 数据库/初始化要求 |
| --- | --- | ---: | --- | --- |
| 员工权限 | [tests/business_api/admin/test_support_role_concurrency.py](../../tests/business_api/admin/test_support_role_concurrency.py) | 4 | `STAFF_PASSWORD_TEST_DATABASE_URL` | loopback 专用 DB，不得使用 postgres/template0/template1；自建 schema |
| Outbox/审计 | [tests/business_api/audit/test_outbox_publication_receipts.py](../../tests/business_api/audit/test_outbox_publication_receipts.py) | 1 | `OUTBOX_PUBLICATION_TEST_DATABASE_URL` | 必须 127.0.0.1:54836/outbox_publication_test，用户名 outbox_fixture，不允许 URL query；自建 schema |
| 账本审计 | [tests/business_api/audit_pg/test_f01_f02_transactions.py](../../tests/business_api/audit_pg/test_f01_f02_transactions.py) | 7 | `RUN_POSTGRES_TESTS=1 + AUDIT_PG_URL` | 会 drop_all/create_all；仅全新可销毁数据库 |
| 账本报表 | [tests/business_api/audit_pg/test_statements_pg.py](../../tests/business_api/audit_pg/test_statements_pg.py) | 2 | `RUN_POSTGRES_TESTS=1 + AUDIT_PG_URL` | 会 drop_all/create_all；独占临时数据库 |
| 钱包审计 | [tests/business_api/audit_pg/test_wallet_pg.py](../../tests/business_api/audit_pg/test_wallet_pg.py) | 13 | `RUN_POSTGRES_TESTS=1 + AUDIT_PG_URL` | 删除/重建相关表；独占临时数据库 |
| 后台认证 | [tests/business_api/identity/test_admin_sessions_pg.py](../../tests/business_api/identity/test_admin_sessions_pg.py) | 3 | `ADMIN_AUTH_TEST_PG_URL` | 自建 admin_auth_* schema |
| 账号绑定 | [tests/business_api/identity/test_binding_uniqueness_postgres.py](../../tests/business_api/identity/test_binding_uniqueness_postgres.py) | 4 | `ACCOUNT_CREDENTIALS_POSTGRES_URL` | 复用账号夹具；必须 127.0.0.1/credentials_test |
| 身份/通信恢复 | [tests/business_api/identity/test_matrix_recovery.py](../../tests/business_api/identity/test_matrix_recovery.py) | 10 | `CHATFLOW_RECOVERY_TEST_DSN` | 原生 psycopg DSN；独立 task_3a_* schema；SQLite 的 PG 锁用例仍有 1 项适用性跳过 |
| 移动认证 | [tests/business_api/identity/test_mobile_sessions_pg.py](../../tests/business_api/identity/test_mobile_sessions_pg.py) | 8 | `MOBILE_AUTH_TEST_PG_URL` | 自建 mobile_auth_* schema |
| 手机注册 | [tests/business_api/identity/test_phone_onboarding_postgres.py](../../tests/business_api/identity/test_phone_onboarding_postgres.py) | 1 | `PHONE_ONBOARDING_POSTGRES_URL` | 自建 phone_onboarding_* schema |
| 用户名/并发 | [tests/business_api/identity/test_username_change_pg.py](../../tests/business_api/identity/test_username_change_pg.py) | 5 | `MOBILE_AUTH_TEST_PG_URL` | 自建 username_* schema |
| 动态草稿 | [tests/business_api/moments/test_moment_draft_cas_postgresql.py](../../tests/business_api/moments/test_moment_draft_cas_postgresql.py) | 5 | `MOMENTS_TEST_DATABASE_URL` | 强制 PostgreSQL 16；自建 schema 和依赖闭包表 |
| 充值通知 | [tests/business_api/recharge/test_order_notifications_postgres.py](../../tests/business_api/recharge/test_order_notifications_postgres.py) | 1 | `STARCHAT_NOTIFICATION_TEST_DATABASE_URL` | 数据库名必须 support_notifications_ 开头；夹具 create_all |
| 充值绑定 | [tests/business_api/recharge/test_recharge_binding_concurrency.py](../../tests/business_api/recharge/test_recharge_binding_concurrency.py) | 3 | `SUPPORT_ORDER_POSTGRES_URL` | loopback，数据库名 wallet_gate 开头；预先完整迁移 |
| 客服充值 | [tests/business_api/recharge/test_support_order_postgres.py](../../tests/business_api/recharge/test_support_order_postgres.py) | 2 | `SUPPORT_ORDER_POSTGRES_URL` | 预先完整迁移，断言 alembic_version 存在 |
| 红包领取 | [tests/business_api/redpacket/test_claim_filter_postgres.py](../../tests/business_api/redpacket/test_claim_filter_postgres.py) | 6 | `REDPACKET_QUERY_TEST_DATABASE_URL` | 数据库名 redpacket_optimization，loopback；预先完整迁移 |
| 账号凭据 | [tests/business_api/test_account_credentials_postgres.py](../../tests/business_api/test_account_credentials_postgres.py) | 9 | `ACCOUNT_CREDENTIALS_POSTGRES_URL` | 必须 127.0.0.1/credentials_test；自建 schema |
| 数据库连接 | [tests/business_api/test_database.py](../../tests/business_api/test_database.py) | 1 | `RUN_POSTGRES_TESTS=1 + BUSINESS_DATABASE_URL` | 专用临时库；只启用标志而不设 URL 会误用默认配置 |
| 支付 PIN | [tests/business_api/test_payment_pin_postgres.py](../../tests/business_api/test_payment_pin_postgres.py) | 3 | `PAYMENT_PIN_TEST_DATABASE_URL` | 夹具自建 payment_pin_test_* schema |
| 完整迁移 | [tests/business_api/test_production_migration_chain.py](../../tests/business_api/test_production_migration_chain.py) | 6 | `REPORTING_PG_URL` | 自建 schema，测试历史迁移升级及数据保全 |
| 提现资金并发 | [tests/business_api/test_wallet_payout_funding_postgres.py](../../tests/business_api/test_wallet_payout_funding_postgres.py) | 2 | `PAYMENT_PIN_TEST_DATABASE_URL` | 复用 PIN 夹具；合成资金，无外部托管 |
| 入账修复 | [tests/business_api/wallet/test_admin_deposit_repairs_postgres.py](../../tests/business_api/wallet/test_admin_deposit_repairs_postgres.py) | 3 | `REPORTING_PG_URL` | 自建 schema；实际迁移与修复约束 |
| 充值匹配 | [tests/business_api/wallet/test_automatic_recharge_matching_postgres.py](../../tests/business_api/wallet/test_automatic_recharge_matching_postgres.py) | 1 | `RECHARGE_MATCH_TEST_DATABASE_URL` | loopback/support_matching_review；自建 schema 并迁移 |
| 入账兑换 | [tests/business_api/wallet/test_deposit_auto_conversion_postgres.py](../../tests/business_api/wallet/test_deposit_auto_conversion_postgres.py) | 1 | `REPORTING_PG_URL` | 自建 schema 并迁移 |
| 人工入账约束 | [tests/business_api/wallet/test_manual_deposit_case_constraints.py](../../tests/business_api/wallet/test_manual_deposit_case_constraints.py) | 4 | `REPORTING_PG_URL` | 自建 schema，0065→0066 升级；不可提前覆盖历史阶段 |
| 人工入账 | [tests/business_api/wallet/test_manual_deposit_cases_postgres.py](../../tests/business_api/wallet/test_manual_deposit_cases_postgres.py) | 1 | `REPORTING_PG_URL` | 自建 schema 并迁移 |
| 过期证据重采样 | [tests/business_api/wallet/test_manual_expired_resample_postgres.py](../../tests/business_api/wallet/test_manual_expired_resample_postgres.py) | 2 | `REPORTING_PG_URL` | 自建 schema 并迁移；真实锁等待 |
| 客服提现 | [tests/business_api/wallet/test_support_payout_postgres.py](../../tests/business_api/wallet/test_support_payout_postgres.py) | 13 | `SUPPORT_PAYOUT_TEST_DATABASE_URL` | loopback/support_payout_review；夹具测试 0092→head 等迁移 |
| 客服直接结算 | [tests/business_api/wallet/test_support_recharge_direct_settlement.py](../../tests/business_api/wallet/test_support_recharge_direct_settlement.py) | 1 | `SUPPORT_ORDER_POSTGRES_URL` | 自建 direct_* schema 并迁移 |
| 客服收款凭据 | [tests/business_api/wallet/test_support_recharge_receipts.py](../../tests/business_api/wallet/test_support_recharge_receipts.py) | 1 | `SUPPORT_RECEIPT_TEST_DATABASE_URL` | 自建 receipt_* schema 并迁移 |
| 钱包绑定 | [tests/business_api/wallet/test_wallet_binding_pg.py](../../tests/business_api/wallet/test_wallet_binding_pg.py) | 1 | `WALLET_BINDING_TEST_DATABASE_URL` | 必须 127.0.0.1/wallet_binding_verify；预先完整迁移 |
| 钱包事件 | [tests/business_api/wallet/test_wallet_incidents.py](../../tests/business_api/wallet/test_wallet_incidents.py) | 1 | `INCIDENT_PG_URL` | 设置后新增 PG 参数变体；SQLite 并发用例仍跳过 |
| 钱包监控锁 | [tests/business_api/wallet/test_wallet_monitor_lock.py](../../tests/business_api/wallet/test_wallet_monitor_lock.py) | 1 | `REPORTING_PG_URL` | 设置后新增 PG 参数变体；内存 SQLite 跨进程用例仍跳过 |
| 钱包运营迁移 | [tests/business_api/wallet/test_wallet_operations_migration.py](../../tests/business_api/wallet/test_wallet_operations_migration.py) | 1 | `REPORTING_PG_URL` | 自建 schema，执行 0041 升级与保全检查 |
| 通信恢复 | [tests/infra/test_synapse_recovery_postgres.py](../../tests/infra/test_synapse_recovery_postgres.py) | 20 | `CHATFLOW_RECOVERY_TEST_DSN` | 原生 psycopg DSN；夹具自建 task_3a_* schema |
| iOS 权限 hook | [tests/mobile/test_ios_permission_capabilities.py](../../tests/mobile/test_ios_permission_capabilities.py) | 1 | `PATH 中可用的 Ruby` | 实际执行 Podfile post_install；不需要完整 CocoaPods/Xcode，不等于 iOS 编译或真机验收 |

Worker 另有 15 项 PostgreSQL 场景，不包含在上述 148 项内：`tests/business_worker/test_worker_active_lease_postgres.py`、`test_worker_claim_fencing_postgres.py` 共 14 项，以及 `test_worker_lease_window.py::test_postgres_two_consumers_do_not_replay_unstarted_tail` 1 项。变量为 `IM_WORKER_LEASE_TEST_DATABASE_URL`，要求 loopback、数据库名 `im_worker_lease_` 开头。前两组自建 schema；租约窗口用例直接在专用数据库建队列表，必须使用新的任务数据库，不复用活动实例数据。本轮在独立 PostgreSQL 16.9 中 14+1 均通过；每次改 claim/renew/fencing/重试都应执行。

## 本地执行方法

每组使用新的 PowerShell 会话和任务独占、可销毁的本地 PostgreSQL 实例/数据库；不要将根 `.env` 或生产 DSN 复制进测试配置。数据库角色需要该临时库的建 schema/DDL 权限，不应拥有任何生产库权限。固定 PostgreSQL 16.9；动态草稿夹具明确要求主版本 16。

先按上表建立数据库和环境变量，再从仓库根执行：

```powershell
$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
$python = (Resolve-Path -LiteralPath '.venv312/Scripts/python.exe').Path
& $python scripts/python_environment.py check
if ($LASTEXITCODE -ne 0) { throw 'Python environment check failed' }
$env:BUSINESS_SMS_ALIYUN_CODE_VALID_MINUTES = '15'
$env:PYTHONPATH = @(
  'services/business-api', 'services/business-worker/app', (Get-Location).Path,
  'tests/business_api', 'tests/business_api/identity', 'tests/business_api/wallet',
  'tests/business_api/recharge', 'tests/business_api/moments'
) -join [IO.Path]::PathSeparator
$run = 'docs/verification/artifacts/' + (Get-Date -Format 'yyyy-MM-dd') + '/module-' + [Guid]::NewGuid().ToString('N')
New-Item -ItemType Directory -Path $run | Out-Null
$temp = ([IO.Path]::GetFullPath($run) + '/pytest').Replace('\','/')
$env:PYTEST_ADDOPTS = '-ra --basetemp="' + $temp + '"'
# 将路径换成上表本次变更涉及的文件；该例需要先设置专用租约测试 URL。
& $python -m pytest tests/business_worker/test_worker_active_lease_postgres.py tests/business_worker/test_worker_claim_fencing_postgres.py tests/business_worker/test_worker_lease_window.py::test_postgres_two_consumers_do_not_replay_unstarted_tail -q
if ($LASTEXITCODE -ne 0) { throw 'Module gate failed' }
```

表中标注“预先完整迁移”的库，必须确认属于当前任务后，在独立进程设置 `BUSINESS_DATABASE_URL` 为该库，切换到 `services/business-api`，令 `PYTHONPATH=.`，运行同一个绝对路径解释器的 `-m alembic upgrade head`。其余历史迁移夹具自己控制起始 revision，不统一预迁移；全局 RUN_POSTGRES_TESTS 也只在审计/连接组启用。执行后核对退出码和实际收集的 PG 参数；缺条件的 skip 不算通过。

清理顺序：等待 pytest/连接退出 → 保存日志、源码/锁 SHA、数据库版本和测试摘要 → 校验容器/数据目录属于本任务 → 正常停止并删除该临时实例及专属匿名卷。不得使用全局 docker prune，也不能删除共享 PostgreSQL 数据。夹具虽有 finally 清理，失败中途创建的表仍以销毁任务实例兜底。

Ruby hook 可在具备 Ruby 的宿主执行 `& $python -m pytest tests/mobile/test_ios_permission_capabilities.py -q -ra`。原生 iOS 编译仍需 macOS/Xcode；企业签名及保数据升级另按移动交付流程和实际设备验收。Windows 上 hook 通过也不能替代这些条件。

## 发布、归档与例行检查

- 每次修改：根规则/当前状态/任务 → CodeGraph → 小范围 RED/GREEN → 按影响执行 verify 和本表 → 更新契约与证据 → 规格审查 → 质量安全审查。
- 依赖变更：保持精确版本；更新权威生产锁后重新派生开发输入，记录 pip check 和平台差异，审阅 vendored/native 兼容。弃用警告单独登记，不批量无依据升级。
- 同步前：fetch、比较提交范围/远程漂移、检查凭据与大对象、核对 CI 触发和发布身份；仅正常显式分支推送，不带 tags，不 force/rebase。
- 归档清理前：逐文件保全并复核哈希、受限 ACL、恢复入口，确认无未提交/未推送/未合入工作及进程/句柄占用；使用 git worktree remove。
- 发布时：Android2233/iOS2215 是本轮保留基线；后续以当前状态和实际工件为准。源码修改需对应平台验证，原工件重分发复用构建证据。历史 iOS 签名团队不一致仍需下次发布单独核对，不将授权发布写成严格验签通过。
