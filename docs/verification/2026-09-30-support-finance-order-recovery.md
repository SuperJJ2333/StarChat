# 客服资金订单恢复：实施与发布证据

## 2026-09-30 基线

- 工作树：`C:/Users/Administrator/.codex/worktrees/wallet-ui-polish/StarChat`，分支 `codex/wallet-ui-polish-20260929`；实施前源码 commit `1a246939261b076b25299260875126ab0a987445`，`git status --short` 无输出。
- 用户授权：在书面规格批准后，用户明确要求“修改产品代码和生产环境”。受保护 ADR 与逐项计划按该授权执行，生产发布仍须通过计划中的门禁。
- 本机：PowerShell 7 UTF-8 无 BOM 会话；Python 3.12.10、Node v22.22.2、Docker Server 29.2.1；独立工作树无 `.env`；`scripts/verify.ps1` 存在。启动前无运行容器，也未配置本地专项 PostgreSQL URL；因此建立仅监听 `127.0.0.1:25487` 的临时 `postgres:16.9-alpine` 容器 `starchat-support-recovery-pg`，专用库 `support_payout_review`、`support_order_review`，没有生产连接或数据。前者供测试按随机 schema 自建，后者从空库迁至本地唯一 0092 head。
- 本地 Alembic 唯一 head：`0092_admin_session_entry_mode`。第一次从仓库根调用 `alembic heads` 因迁移路径相对工作目录而失败；改在 `services/business-api` 目录执行得到该 head，未更改配置。
- 基线命令：`py -3.12 -m pytest tests/business_api/wallet/test_support_payout.py tests/business_api/wallet/test_manual_payouts.py tests/business_api/recharge/test_support_order_workflow.py tests/business_api/tron/test_reader.py -q`，退出码 0，`143 passed in 22.83s`。
- 基线命令：`node --test frontend/tests/admin-support-payouts.test.mjs frontend/tests/admin-recharge-panel.test.mjs`，退出码 0，`46 passed, 0 failed`。
- 隔离 PostgreSQL 基线：为两专用库设置 `SUPPORT_PAYOUT_TEST_DATABASE_URL`、`SUPPORT_ORDER_POSTGRES_URL`，运行 `py -3.12 -m pytest tests/business_api/wallet/test_support_payout_postgres.py tests/business_api/recharge/test_support_order_postgres.py -q`，退出码 0，`4 passed in 8.67s`；后续迁移/并发仍需在最终候选重跑。
- 生产只读快照，2026-09-30 00:27:03 +08:00：API 运行镜像 `sha256:fadabb52cd61c078599ceda2544cea6f34dd85b0dbc0b6c5d276c5d3a96ab7dd`，比本工作树前次钱包 UI 发布时的 `83aedc06` 更新；Worker 仍为 `sha256:3c9e4bbf4760edd173263efb8a8ad2cbee99af9a287402c4d885f5186eaadaaf`。两者 healthy、重启 0。生产 Alembic current/head 均为唯一 `0092_admin_session_entry_mode`。生产 payout 核心、客服协调、Tron reader、充值流程的文件 SHA 与本工作树一致；两块提现/充值前端的原始 SHA 不同，经只读逐字节比较，差异仅是本地 CRLF 与生产 LF（分别 106/620 行），代码内容相同。发布清单要明确行尾归一和最终原始 SHA，不能从旧 `83aedc06` 镜像发布。公开 ready 为 200、匿名后台入口为 401；服务器静态与公网严格 TLS 回读一致。Compose 配置 SHA、备份路径仍在只读复核中，切换前须再次冻结。

## 实施门禁

- 隔离 PostgreSQL 迁移/并发/资金验证：待建立隔离数据库并运行。
- 红灯/绿灯证据、OpenAPI 与后台契约、领域/规格审查、独立质量安全审查、完整验证：待执行。
- 候选与兼容回退镜像、真实 Compose 与续期协议、生产发布及公网检查：待执行。
- 历史已开始订单：不自动退款或回拨；没有用户提供的具体订单号，不进行单笔资金操作。
