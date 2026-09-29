# 客服资金订单恢复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

状态：用户已批准[书面规格](../specs/2026-09-29-support-finance-order-recovery-design.md)及汇率/地址安全修订，并于 2026-09-30 明确要求“修改产品代码和生产环境”，批准按[受保护 ADR](../../adr/2026-09-29-support-finance-order-recovery.md)和本计划实施及受控生产发布。测试、审查、现网基线与回退门禁仍须逐项满足。

**Goal:** 让客服提现在真正开始出款前可取消、拒绝与重调汇率；安全发现及核验链上付款；让他人认领的提现/充值真实禁用，并由官方钱包所有者管理员受控接管。

**Architecture:** 沿用 `ManualPayoutService` 的唯一 USDT/点钻账本与 `SupportPayoutState` 认领状态。准备汇率只写客服协调状态，真正开始出款在一个资金事务应用差额、锁定最终条款和付款资格；TronGrid 历史仅找 txid，所有路径由现有固化收据和新增跨订单归属门禁结算。接管使用实际管理会话与当次操作证明，已开始订单只移交证据权。后台按服务端能力渲染并在开始后才读取完整地址。

**Tech Stack:** FastAPI/Pydantic、SQLAlchemy/Alembic、PostgreSQL、pytest、TronGrid 现有 reader/finality、原生 JavaScript/CSS、Node test runner、PowerShell 7。

---

## 授权、基线与任务所有权

- 用户本轮选定：取消/拒绝截止于“确认开始出款”；可返回订单列表并在此之前重调汇率；TronGrid 查候选后人工选择；仅配置的官方钱包所有者管理员可单独确认、审计接管；本轮发布后台与 API，Android 后续。用户另批准“保存汇率不动冻结，完整地址在开始成功后开放”。历史已开始订单只读取证，不自动退款。
- 工作树为 `C:/Users/Administrator/.codex/worktrees/wallet-ui-polish/StarChat`，文档基线 `ffc9132b`。根 `D:` 工作区有其他任务未提交内容，本计划不在那里开发。执行前重新读 `docs/runbooks/admin-production-workflow.md`、`docs/runbooks/mobile-delivery-workflow.md`、`docs/workflow/current-state.md`、本 ADR/规格及 `docs/workflow/tasks/2026-09-29-support-finance-order-recovery.md`，并核对 `AGENTS.md` 与更深层规则。当前独立树没有 `.codegraph/`；若后续出现索引，先使用 CodeGraph。
- **单文件所有权按任务串行**：Tasks 2–5、8 顺序修改 `support_payout.py`；Tasks 3–4、7 顺序修改 `manual_payouts.py`；Tasks 9–10 分别拥有提现与充值前端。Tron reader/finality 的 Task 6 可与纯前端测试设计并行，但路由 `api/support_payout.py` 只能由一人串行集成。Task 11 统一接线和 OpenAPI；任何代理不得并发编辑同一文件。
- 本计划不改旧 `OWNER_MANUAL_V1` 付款策略、现有账本历史、imToken 签名、固定 USDT 合约、用户资产精度、充值独立审批或 Android/iOS 源码。生产事实须发布前重查，不引用本调查快照作为实时镜像。

## 文件职责与合同

| 文件 | 本轮职责 |
| --- | --- |
| `services/business-api/migrations/versions/0093_support_finance_order_recovery.py`、`tests/business_api/test_migrations.py` | 以本工作树 0092 head 为父的 expand 迁移；新准备/拒绝不可变记录、证据接管状态与约束；生产 head 漂移则先修订计划和迁移链。 |
| `app/modules/wallet/support_payout.py`（位于 `services/business-api/` 下） | 汇率准备、认领/证据能力投影、开始/拒绝/接管状态；不直接改跨模块表。 |
| `app/modules/wallet/manual_payouts.py`、`conversions.py`、`service.py`、`app/modules/ledger/service.py` | 原子开始/最终摘要、精确取消/拒绝释放、受益账户与实际操作人、最终链上归属门禁。 |
| `app/integrations/tron/reader.py`、`app/modules/wallet/runtime.py` | 有界历史 txid 发现与现有 finality 注入；不构建第二来源。 |
| `app/modules/recharge/workflow.py`、`service.py`、`models.py` | 已存在租约的管理员安全移交，已付款/绑定/结果不明按原状态机证明，不重发点钻。 |
| `app/modules/identity/support_order_auth.py`、`operation_password.py`、`app/api/support_payout.py`、`app/api/recharge.py` | 当前角色、会话、选定模式的当次操作证明，新的严格式请求/响应。 |
| `frontend/src/admin-support-payout-panel.js`、`admin-recharge-panel.js`、`admin-api.js`、`styles/admin-wallet.css` | 返回/调汇率/拒绝/链上候选/地址复制、禁用和管理员接管；服务端权威状态与身份失效清理。 |
| `packages/api-contracts/openapi/liuhetong-v1.yaml`、`docs/runbooks/wallet-incident-recovery.md` | 发布契约、兼容错误消息和手工恢复操作。 |

精确接口草案：`POST /api/v1/admin/support-orders/payouts/{id}/adjust-rate` 保存带 `expected_preparation_version` 的准备值；`/begin-payment` 对点钻来源要求最新 `expected_preparation_version + expected_digest`，USDT 来源用原摘要；新增 `/reject`、`/takeover`、`/payment-address/read`、`/discover`、`/select-discovered`。提现接管使用状态 `version` 作为 `expected_claim_version`；充值新增 `POST /api/v1/recharge/admin/requests/{id}/takeover`，使用申请单 `claim_version`。列表/详情增加服务端 `claimed_by`、处理资格和准备值版本；旧核心状态枚举不新增值。所有新写请求必须有独立 `Idempotency-Key`、稳定原因、实际 actor、审计与事务 Outbox；浏览器只在有明确结果时生成下一操作键，未知结果先查询。

## Task 1：环境、现网基线与红灯证据

**Files:** Modify `docs/workflow/tasks/2026-09-29-support-finance-order-recovery.md`; Create `docs/verification/2026-09-29-support-finance-order-recovery.md`.

- [ ] **Step 1:** 在 PowerShell 7 每个会话设置无 BOM UTF-8 输入/输出和 `PYTHONUTF8=1`、`PYTHONIOENCODING=utf-8`；记录 `git rev-parse HEAD`、`git status --short`、`py -3.12 --version`、`node --version`、`docker version`、`Test-Path -LiteralPath '.env'`、磁盘和 `scripts/verify.ps1`。检查本地 Alembic 唯一 head 与生产实时 schema。把已提交规格/ADR/计划的批准状态、文件所有权和实际开始时间写任务台账。
- [ ] **Step 2:** 通过 `scripts/starchat-server.ps1` 使用既有 SSH jumper **只读**记录现网 API/Worker 镜像 digest、静态 SHA、Compose、迁移版本、健康、相关订单数量与备份路径，不读取或记录完整钱包地址/凭据。若生产已有后继钱包实现或 schema，暂停计划中的迁移编号和发布步骤，先对差异修订并重新审阅。
- [ ] **Step 3:** 先跑基线专项，精确记录 exit code、通过/跳过数和输入 SHA；缺少本地专用 PostgreSQL 时标为未满足门禁，不把 skip 当通过：

```powershell
$u8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding=$u8; [Console]::OutputEncoding=$u8; $OutputEncoding=$u8
$env:PYTHONUTF8='1'; $env:PYTHONIOENCODING='utf-8'
$env:PYTHONPATH='services/business-api;.'
py -3.12 -m pytest tests/business_api/wallet/test_support_payout.py tests/business_api/wallet/test_manual_payouts.py tests/business_api/recharge/test_support_order_workflow.py tests/business_api/tron/test_reader.py -q
node --test frontend/tests/admin-support-payouts.test.mjs frontend/tests/admin-recharge-panel.test.mjs
```

- [ ] **Step 4:** 写入专项验证记录，提交仅台账/证据。后续每个任务均在同一记录追加红灯、绿灯、代码 SHA、耗时和失败分类。

## Task 2：expand 迁移与不可变客服决策状态

**Files:** Create `services/business-api/migrations/versions/0093_support_finance_order_recovery.py`; Modify `services/business-api/app/modules/wallet/support_payout.py`, `services/business-api/app/modules/recharge/models.py` and `tests/business_api/test_migrations.py`; Test `tests/business_api/wallet/test_support_payout_postgres.py`.

- [ ] **Step 1: Red.** 在真实 PostgreSQL 迁移测试断言 0092→0093 后旧 `wallet_support_payout_states` 行保留且新列为 NULL/0；`wallet_support_payout_rate_preparations` 对 `(order_id, version)` 唯一，`wallet_support_payout_rejections` 对 `order_id` 唯一；ORM **与原生 SQL** 更新/删除既成准备或拒绝记录均失败，重复执行迁移或后继 schema 不丢历史。先运行 `py -3.12 -m pytest tests/business_api/test_migrations.py tests/business_api/wallet/test_support_payout_postgres.py -q`，保存缺模型/列/DB 触发器或 head 断言的预期失败。
- [ ] **Step 2: Green.** 以 `revision='0093_support_finance_order_recovery'`、`down_revision='0092_admin_session_entry_mode'` 创建 expand 迁移：提现状态表增 `prepared_rate NUMERIC(20,6)`、`prepared_receive NUMERIC(30,6)`、`prepared_digest VARCHAR(64)`、`prepared_version INTEGER NOT NULL DEFAULT 0`、`evidence_actor_id`、`evidence_token_hash`、`evidence_version INTEGER NOT NULL DEFAULT 0`；充值申请表增 `claim_version INTEGER NOT NULL DEFAULT 0` 并由认领/接管递增；准备历史表记录订单、版本、率、六位金额、摘要、原因、actor、时间；拒绝表记录订单、actor、原因、时间并以订单唯一。两张不可变历史表沿用 `0005_audit_events.py`/`0007_caibi_ledger.py` 的 PostgreSQL UPDATE/DELETE 拒绝触发器模式，并加 ORM 守卫，不接受只靠应用层约定；旧行没有准备值，点钻来源须先经新页面保存，USDT 来源使用原报价。`downgrade()` 明确拒绝破坏性删除。
- [ ] **Step 3:** 跑 Step 1 的迁移/PG 用例，核实唯一 head 与 0092 备份恢复演练；并跑 `py -3.12 -m pytest tests/business_api/wallet/test_support_payout.py -q`。绿后提交迁移、模型与测试，不修改已有 0046/0076/0087 历史脚本。

## Task 3：精确释放与“受益账户/实际操作人”账本证明

**Files:** Modify `services/business-api/app/modules/wallet/conversions.py`, `services/business-api/app/modules/wallet/service.py`, `services/business-api/app/modules/ledger/service.py`, `services/business-api/app/modules/wallet/manual_payouts.py`; Test `tests/business_api/wallet/test_manual_conversions.py`, `tests/business_api/wallet/test_manual_payouts.py`, `tests/business_api/wallet/test_manual_payout_rate.py`, `tests/business_api/wallet/test_payout_funding_pin.py` and `tests/business_api/ledger/test_ledger.py`.

- [ ] **Step 1: Red.** 增加两组明确断言：用户取消仍以用户 actor、`MANUAL_PAYOUT_CANCELLED` 精确释放原 `HOLD` 和原兑换；客服拒绝以实际客服 actor、`MANUAL_PAYOUT_REJECTED` 产生关联镜像账本事务，而两组均按原 conversion 的 `source_amount`/`target_amount` 证明、同键重放不重复、不同 actor/原因不能借原收据跨单释放。调低准备率后差额仍锁在原 `HOLD`、不能被第二张申请消费；若用户用其他可用 USDT 另开订单，原单取消仍成功且各资产余额与负债平衡。运行上述五组文件，确认缺少真实 actor 接口的红灯。
- [ ] **Step 2: Green.** 在公开方法中把账户与执行人分成显式参数，例如 `reverse_payout_conversion(session, factory, *, user_id, actor_id, reason_code, order_id, amount)` 与 `require_conversion_release(..., user_id, actor_id, reason_code, ...)`；`LedgerService._require_conversion_replacement` 用 `user_id` 核验原转换和用户分录，用 `actor_id` 核验新冲正事务，保留唯一 `reversal_of_id`、`reverse:<conversion_id>` 和精确镜像。将 `ManualPayoutService.cancel` 的释放逻辑提取为同事务私有步骤供新拒绝调用，不能让另一个模块直接写钱包/账本表；原 OWNER 与旧用户取消回归保持原 actor/reason。
- [ ] **Step 3:** 复跑 Step 1 文件及 `tests/business_api/wallet/test_manual_ledger_integrity.py`；用隔离 PG 并发测试保证取消/拒绝/开始三者单赢家，失败不部分释放。绿后提交接口、证明和测试。

## Task 4：汇率准备与原子开始出款

**Files:** Modify `services/business-api/app/modules/wallet/support_payout.py`, `services/business-api/app/modules/wallet/manual_payouts.py` and `services/business-api/app/api/support_payout.py`; Test `tests/business_api/wallet/test_support_payout.py`, `tests/business_api/wallet/test_support_payout_postgres.py` and `tests/business_api/wallet/test_manual_payout_rate.py`.

- [ ] **Step 1: Red.** 加测试：认领及两次 `adjust-rate` 后核心订单仍 `REQUESTED`，`execution_started_at`、`final_rate/final_receive` 与用户余额/`HOLD` 不变，准备版本递增且历史不可变；失败准备不改变状态；USDT 来源 `adjust-rate` 409；点钻来源 begin 接受最新版本/摘要，旧版本或原摘要 409，余额不足/储备过期则整个 begin 回滚且仍可取消；USDT 来源用原金额/摘要/初始冻结开始。先运行三个专项文件得到预期红灯。
- [ ] **Step 2: Green.** 把 `SupportPayoutService.adjust_rate` 改为只在 `REQUESTED` 和有效令牌下保存准备记录；`RateBody` 增 `expected_preparation_version: int | None = Field(default=None, ge=0)`，缺失或过时均由服务返回 409，以阻止旧静态页面和旧标签页覆盖。`BeginBody` 增 `expected_preparation_version: int | None = Field(default=None, ge=0)`；点钻来源要求该版本和**唯一当前** `prepared_digest`，USDT 来源只认原 `row.digest`。在 `ManualPayoutService.claim` 的同一个 `factory.begin()` 内完成准备金额的六位 `Decimal` 校验、原 `_limits`/`_gate`/储备复核、用户 USDT 与 `HOLD` 差额分录、最终率/额/摘要及 `CLAIMED` 写入；`_PayoutAuthorization` 的开始时间跟随同事务提交，失败自动回滚。重复开始只返回原不可变指令，不执行新分录。调用方不得先独立调用 `begin_payment` 再调率。
- [ ] **Step 3:** 复跑专项和真实 PG 的取消/begin、两位客服调率、旧标签页 begin 竞争用例；核对原 `OWNER_MANUAL_V1` rate/claim 测试。绿后提交。

## Task 5：客服拒绝、中文取消错误和终态投影

**Files:** Modify `services/business-api/app/modules/wallet/support_payout.py`, `services/business-api/app/modules/wallet/manual_payouts.py`, `services/business-api/app/modules/identity/support_order_auth.py` and `services/business-api/app/api/support_payout.py`; Test `tests/business_api/wallet/test_support_payout.py`, `tests/business_api/wallet/test_manual_payouts.py` and `tests/business_api/wallet/test_support_payout_postgres.py`.

- [ ] **Step 1: Red.** 增加 `reject` 测试：只接受 `REQUESTED`、未开始、无候选凭证、当前有效令牌，以及 `FINANCE_SUPPORT` 或配置 owner `SUPER_ADMIN`；**配置 owner 即使兼任财务客服也必须在本次请求提供选定模式的新鲜操作密码/TOTP**，只有 48 小时会话或旧 60 分钟 grant 时拒绝，证明过期或提交前撤权回滚。原因仅为 `PAYOUT_ADDRESS_INVALID`、`PAYOUT_DETAILS_MISMATCH`、`PAYOUT_POLICY_INELIGIBLE` 之一。拒绝与用户取消/begin 并发只能一方提交；冻结/原兑换精确冲正，准备率失效、不可变拒绝记录/实际 actor/审计/Outbox 原子提交；旧令牌、撤销角色、不同幂等内容拒绝。确认旧 Android 收到 `code=WALLET_PAYOUT_CANNOT_CANCEL` 和中文 `message`，且已开始或未知结果不被退款。运行三个文件，留预期失败。
- [ ] **Step 2: Green.** 新 `RejectBody(LeaseBody)` 用 `Literal` 严格限制三个稳定原因，另含仅供配置 owner 使用的 `AdminWalletProofBody`；`POST /{order_id}/reject` 要求 `Idempotency-Key`。在 `support_order_auth.py` 增只服务本次资金动作的 `verify_fresh_owner_operation`：按选定 `wallet_admin_auth_mode` 直接验证操作密码或 TOTP，绑定 actor、管理会话、订单和动作，30 秒内提交前重验；不调用可复用 wallet grant 充当证明。`SupportPayoutService.reject` 在同一 `_order_lock` 事务通过带提交前终检的 `_PayoutAuthorization` 和 owner 证明，调用 Task 3 的公开释放接口并插入不可变拒绝行；`support_payout_projection` 将该行投影为 `REJECTED`，核心保持 `CANCELLED`。仅对 `WALLET_PAYOUT_CANNOT_CANCEL` 生成阶段明确的中文 `message`，保留原 `code`，不可把所有内部错误默认翻译成成功或允许取消。Task 9/10 复用同一 owner 当次证明边界。
- [ ] **Step 3:** 复跑上述测试和链接账本测试；对一张历史已开始订单做**测试库内**回归，断言不因未到账而可拒绝。绿后提交。

## Task 6：开始后受控读取和复制完整客户地址

**Files:** Modify `services/business-api/app/modules/wallet/support_payout.py` and `services/business-api/app/api/support_payout.py`; Test `tests/business_api/wallet/test_support_payout.py` and `tests/business_api/wallet/test_support_payout_postgres.py`. Frontend rendering belongs to Task 11.

- [ ] **Step 1: Red.** 测试 `REQUESTED`、仅认领、仅准备汇率的列表/详情/读取接口都不含完整 `target_address`；开始成功后，原证据处理人持有效令牌或当前 owner 管理身份可经单独读取取得报价快照原地址，审计每次读取；普通客服、失权、旧令牌及跨账号请求为 403/404，`Cache-Control: no-store`，日志/错误不回显地址。刷新后的合法读取仍成功。
- [ ] **Step 2: Green.** 用 `POST /{order_id}/payment-address/read` 及请求体 `claim_token: str | None`（不放 URL/query）读取；服务端先核对 `execution_started_at` 和核心 `CLAIMED/UNKNOWN/SETTLED`，再核对当前证据资格或配置 owner 的实时只读权限，从原 `ManualPayoutQuote.snapshot['target_address']` 返回 `{'target_address': value, 'network': 'TRON'}`。只在授权通过后写只读审计，响应 `no-store`；普通列表/详情只返回掩码。后续证据接管须使原令牌在本入口同样失效。
- [ ] **Step 3:** 复跑测试并审查路由/审计日志，没有完整地址进入 URL、日志和普通列表。绿后提交。

## Task 7：TronGrid 有界只读候选发现

**Files:** Modify `services/business-api/app/integrations/tron/reader.py`, `services/business-api/app/modules/wallet/runtime.py`, `services/business-api/app/modules/wallet/support_payout.py` and `services/business-api/app/api/support_payout.py`; Create `tests/business_api/wallet/test_support_payout_discovery.py`; Test `tests/business_api/tron/test_reader.py`, `tests/business_api/wallet/test_tron_finality.py` and `tests/business_api/wallet/test_manual_runtime.py`.

- [ ] **Step 1: Red.** 在 reader 替身测试固定官方地址、合约、确认/固化扫描区间、页数/条数/总时限、重复指纹和格式错误；发现 API 仅从订单取官方/目标/六位金额/开始时刻，客户端不能改条件。零候选返回完整扫描的 `EMPTY` 而不是“证明未付款”；缺页/超限/429/超时是 `INCOMPLETE` 或 `UNAVAILABLE`，订单和账本不变；未开始或无证据权在调用 provider 前拒绝。多笔候选用现有 `transaction_evidence` 固化收据逐一验证，返回缩略哈希、脱敏目标、精确金额/时间/状态，不泄漏完整地址。
- [ ] **Step 2: Green.** 在 `TronReader` 增公开 `discover_transaction_ids(address: str, start_ms: int, end_ms: int)`：先获取固化头，设置独立 `max_scan_seconds` 截止，复用带 `only_from=true` 的有界 `_transactions`，结束时重验头与区间，任何截断均抛 `TronReadError`，不返回“部分完整”。`TronReader._deadline` 是实例可变字段，`runtime` 应注入按请求创建并在 `finally` 关闭的 reader 工厂，使用现行 TronGrid key/URL，不能让两个查询共享截止时间；不得调用会额外读取余额的 `snapshot()` 当作交互发现。服务在 DB 外查询，按固化收据过滤，构造 `GET /{order_id}/discover` 的有界结果。本任务只开放只读发现，候选选择要等 Task 8 的最终归属门禁完成后才接入路由。
- [ ] **Step 3:** 跑 `py -3.12 -m pytest tests/business_api/tron/test_reader.py tests/business_api/wallet/test_tron_finality.py tests/business_api/wallet/test_support_payout_discovery.py tests/business_api/wallet/test_manual_runtime.py -q`；老订单超预算须提示手填完整哈希，不静默截断。绿后提交。

## Task 8：所有 txid 路径共用最终跨订单归属门禁

**Files:** Modify `services/business-api/app/modules/wallet/manual_payouts.py`, `services/business-api/app/modules/wallet/support_payout.py` and `services/business-api/app/api/support_payout.py`; Test `tests/business_api/wallet/test_manual_payouts.py`, `tests/business_api/wallet/test_support_payout_discovery.py` and `tests/business_api/wallet/test_support_payout_postgres.py`.

- [ ] **Step 1: Red.** 构造不同用户、同官方来源、同目标地址、相同六位应付且开始时间窗相交的两张订单；一条固化 Transfer 即便尚未占用，也不能结算任一单。分别通过候选选择、手填 `txid`、更正、重试调用，全部保持 `HOLD`、无 `ManualPayoutEvent`/SETTLED，并有 `ORDER_ATTRIBUTION_AMBIGUOUS` 核对审计；另用唯一归属候选断言选择同时写 `ManualPayoutCandidate` 和核心 `candidate_txid` 后可通过同一 reconcile 结算。并发新 begin 与 reconcile 不得出现先检查后新增竞争订单。没有任何候选时点击 reconcile 只读返回 `CLAIMED`，不写 `UNKNOWN`；多真实匹配事件、已占用或旧收据仍按原安全失败。
- [ ] **Step 2: Green.** 在 `ManualPayoutService.reconcile` 的第二个 `_order_lock` 事务内、写 `ManualPayoutEvent`/账本前调用统一 `_require_unambiguous_owner(session, row, quote, transfer)`。使用已有 `lock_budget(session)` 作为覆盖所有用户/目标的强归属锁；`request`、`claim`/begin 和 reconcile 均持它。查询范围明确为事件时间不早于另一单 `claimed_at`、另一单仍是 `CLAIMED/UNKNOWN`、官方来源/目标和最终整数金额与事件相同的未终结订单；SQL 用 `LIMIT 2` 发现歧义，兼容旧 owner 与新客服策略。目标来自不可变报价，金额来自服务端最终值，不按前端候选判断；查询/锁失败关闭为待核对。无候选时直接返回当前状态，不更新 `review_reason`。完成门禁后才新增 `POST /{order_id}/select-discovered`：仅接服务端发现的 txid，重新取收据/授权/版本，**复用公开 `submit_txid` 应用服务（已有候选时复用 `correct_candidate`）**，原子记录不可变候选、`row.candidate_txid`、`UNKNOWN`、幂等收据/审计/Outbox 后再进入统一 reconcile；不能只插候选表或跨模块直写，因为结算的数据库约束要求 `candidate_txid` 非空。不修改 ADR-0013 的唯一事件约束。
- [ ] **Step 3:** 在本地专用 PostgreSQL 执行 `SUPPORT_PAYOUT_TEST_DATABASE_URL` 指向 `localhost/127.0.0.1` 且 DB 名为 `support_payout_review` 的并发测试（夹具自动建独立 schema）；验证跨用户锁顺序无死锁、两张单不误结算。再跑上列普通测试，绿后提交。

## Task 9：提现管理员接管与已开始订单独立证据权

**Files:** Modify `services/business-api/app/modules/identity/support_order_auth.py`, `services/business-api/app/modules/wallet/support_payout.py`, `services/business-api/app/modules/wallet/manual_payouts.py` and `services/business-api/app/api/support_payout.py`; Test `tests/business_api/wallet/test_support_payout.py`, `tests/business_api/wallet/test_support_payout_postgres.py` and `tests/business_api/identity/test_wallet_access_grant.py`.

- [ ] **Step 1: Red.** 测试仅配置 `wallet_manual_owner_admin_id` 且实时有 `SUPER_ADMIN` 的当前管理会话，在单独确认、稳定原因和**当次提交**选定模式的 TOTP/操作密码后才可接管；仅有 `FINANCE_SUPPORT`、普通 `SUPER_ADMIN`、48 小时会话、60 分钟 grant、失效角色/会话/证明都拒绝。未开始接管替换认领人/令牌/版本，旧令牌不能续租、调价、开始、读取地址。已开始接管保留核心 `claimed_by`/付款指令历史，只授予新证据 token；旧共用 `claim_token` 对重复 begin、重读指令、地址及证据均失效，新证据 token 只能发现/提交/更正/reconcile，不能取得新付款资格。两个管理员并发只能一方提交；同键重放同一结果。
- [ ] **Step 2: Green.** 新 `POST /{order_id}/takeover` 体包含 `expected_claim_version`、稳定 `reason_code` 和严格的 `AdminWalletProofBody`，要求 `Idempotency-Key`；复用 Task 5 的 `verify_fresh_owner_operation`，选定模式的原密码服务 `verify()` 或 TOTP verifier 必须**在本次请求直接验凭据**，不能使用 `WalletAccessGrantService.authorization` 作为新鲜证明。将仅本次请求的验证时间/会话/动作/订单传到持锁命令，提交前重验 owner、管理会话、凭据版本、30 秒新鲜度。未开始轮换 `claim_token`；已开始持久化独立 `evidence_actor_id/evidence_token_hash/evidence_version`，令原 token 所有路径失效。把核心 `submit_txid`/`correct_candidate` 的 `row.claimed_by == admin_id` 硬判断改为仅针对 `SUPPORT_MANUAL_V1` 的公开证据授权回调；旧 OWNER 路径不放宽。付款指令查询仍要求原付款资格且在证据接管后必须拒绝旧 token。`list/detail` 在实时 actor 与状态核验后投影 `can_claim/can_takeover/can_begin/can_evidence`，供 Task 11 使用；接口能力只是显示提示，每次写仍重验。
- [ ] **Step 3:** 复跑专项与本地 PG 并发；检查错误路径不写出凭据/原地址，不创建第二笔付款指令。绿后提交。

## Task 10：充值独占按钮背后的安全接管命令

**Files:** Modify `services/business-api/app/modules/recharge/workflow.py`, `services/business-api/app/modules/recharge/service.py`, `services/business-api/app/modules/recharge/models.py` and `services/business-api/app/api/recharge.py`; Test `tests/business_api/recharge/test_support_order_workflow.py`, `tests/business_api/recharge/test_support_order_http.py`, `tests/business_api/recharge/test_support_order_postgres.py` and `tests/business_api/recharge/test_binding_second_review.py`.

- [ ] **Step 1: Red.** 造两位客服有效认领、owner 单独接管，断言只有配置 owner 且持本次证明/理由/版本可轮换；旧令牌不能 heartbeat/verify/prepare/execute/reject。已有 `evidence_txid`、`receipt_id/payment_verified_at`、活动绑定、已 CREDITED、未确认 execute 结果分别测试：仅有服务端可靠的未执行证明才允许对应证据/复核移交；禁止重置已核验凭证、释放活动绑定、生成第二条调整或重复点钻入账。对 `pending_page`/`admin_requests` 的不同当前 actor 测试 `can_claim/can_takeover/takeover_review_required`，普通客服他人有效认领永不获得接管能力，只有配置 owner 按事实获得只读/受控入口。回撤角色、并发接管、同键不同请求冲突均失败关闭。
- [ ] **Step 2: Green.** 在 `SupportOrderWorkflow` 公开新增 `takeover_order`；持 `lock_budget`→申请单→活动绑定/执行账本锁，重用现有 `claim_order` 的“绑定无执行”证明但不调用会清空 `payment_verified_at` 的 review 分支。普通 `claim_order` 和接管均递增 Task 2 新增的 `RechargeRequest.claim_version`；接管须匹配 `expected_claim_version`。无付款证据/收据/绑定且未执行可轮换普通处理令牌；已有事实时只有收据归属、唯一绑定和调整执行状态均可证明安全移交，才轮换令牌并保留原凭证/到账/绑定，后续任何执行仍只能沿原绑定和既有公共财务门禁。无法证实未执行则只读/待核对，不发新令牌。`RechargeService.pending_page`/`admin_requests` 增当前 actor 输入，在服务端实时会话/角色和申请事实下计算 `can_claim/can_takeover/takeover_review_required`；`api/recharge.py` 列表路由传入当前 actor，接管路由在正常 `command_authorization` 外强制与 Task 9 相同的 owner、当次选定模式验证和提交前复核。不因 `Permission.FINANCE_REVIEW` 或前端 `*` 扩大所有者资格，能力投影不替代每次写的复核。
- [ ] **Step 3:** 跑 `py -3.12 -m pytest tests/business_api/recharge/test_support_order_workflow.py tests/business_api/recharge/test_support_order_http.py tests/business_api/recharge/test_binding_second_review.py -q`；专用本地 `SUPPORT_ORDER_POSTGRES_URL` 指向已迁移隔离库，再跑 `test_support_order_postgres.py`。绿后提交。

## Task 11：提现后台处理闭环

**Files:** Modify `frontend/src/admin-support-payout-panel.js`, `frontend/src/admin-api.js` and `frontend/src/styles/admin-wallet.css`; Test `frontend/tests/admin-support-payouts.test.mjs`, `frontend/tests/admin-support-orders.test.mjs` and `frontend/tests/admin-support-layout.test.mjs`.

- [ ] **Step 1: Red.** 在 DOM 测试断言：他人持有效租约或已开始出款而证据权尚未移交时，普通客服外层按钮文案是“正被其他客服处理中”，`disabled === true` 且点击不调接口；owner 外层仅先打开只读详情，再经单独原因和当次证明提交 takeover。弹窗内“返回提现列表”关闭模态并保留筛选/列表；保存准备汇率后仍显示可取消/拒绝与“确认开始出款”，可再次改率；开始前列表、详情、确认弹窗和剪贴板均无完整地址；开始后单独读取并高亮完整地址，点击复制 icon 传入全部字符，拒绝剪贴板权限显示失败反馈；退出/换账号/撤权清除完整地址。发现候选的空、不完整、冲突、错误、单候选/多候选有不同 UI，必须主动选择后再核验；未知写结果先刷新权威状态，不自动第二次付款。
- [ ] **Step 2: Green.** API 客户端增加 `rejectSupportPayout`、`readSupportPayoutAddress`、`discoverSupportPayout`、`selectSupportPayoutCandidate`、`takeoverSupportPayout` 的固定路径；完整地址与 claim/evidence token 均只在内存。重构 `mutate` 按服务端 `can_claim/can_takeover/can_begin/can_evidence` 能力和响应版本驱动，不以本地 actor role 代替资格；`adjust-rate` 只更新 `prepared_*`，`begin-payment` 显式传当前版本/摘要且须用户二次确认。证据接管后用证据 token 调发现/核验，绝不再展示付款按钮。地址复制使用 `navigator.clipboard.writeText(fullAddress)`，结果以 `role=status` 读屏反馈；无权限立即清除 DOM 和草稿。按钮 `type='button'`、键盘焦点回归和窄屏布局需保持可用。
- [ ] **Step 3:** 运行 `node --test frontend/tests/admin-support-payouts.test.mjs frontend/tests/admin-support-orders.test.mjs frontend/tests/admin-support-layout.test.mjs`；再用浏览器自动化或本地无真实凭据演示页检查 390px 与桌面宽度、模态回退、复制图标和禁用态，截图只存 `docs/verification/artifacts/2026-09-29/support-finance-order-recovery/`。绿后提交。

## Task 12：充值后台被占用状态和管理员安全入口

**Files:** Modify `frontend/src/admin-recharge-panel.js`, `frontend/src/admin-api.js` and `frontend/src/styles/admin-wallet.css`; Test `frontend/tests/admin-recharge-panel.test.mjs`, `frontend/tests/admin-support-orders.test.mjs` and `frontend/tests/admin-support-layout.test.mjs`.

- [ ] **Step 1: Red.** 为列表的“他人有效租约/本人/租约过期/所有者管理员”四类投影加断言：普通客服看到禁用的“正被其他客服处理中”；owner 只能先查看服务端只读状态，点接管后必须二次确认/原因/选定模式证明；已有付款凭证、已核验到账、绑定和结果不明的状态不能被 UI 误标“可直接抢单”。撤权、未知结果和旧响应不得重新启用按钮。
- [ ] **Step 2: Green.** 服务端 `pending_page` 投影增加当前 actor 的 `can_claim/can_takeover/takeover_review_required`，前端只按它渲染；`admin-api.js` 增 `takeoverRecharge` 的带 `Idempotency-Key` 命令。保留现有凭证核验、结算率、绑定及直接下发画面；接管成功以后按服务端保留的原 receipt/binding 状态继续，不生成新财务调整。被占用单的只读详情按钮与禁用的处理按钮分开显示，owner 证明不会写到 DOM、URL、存储或日志。
- [ ] **Step 3:** 跑 `node --test frontend/tests/admin-recharge-panel.test.mjs frontend/tests/admin-support-orders.test.mjs frontend/tests/admin-support-layout.test.mjs`，并用假会话浏览器页验证不遮挡移动端按钮。绿后提交。

## Task 13：契约、迁移恢复文档与全量门禁

**Files:** Modify `packages/api-contracts/openapi/liuhetong-v1.yaml`, `docs/runbooks/wallet-incident-recovery.md`, `docs/workflow/tasks/2026-09-29-support-finance-order-recovery.md` and `docs/verification/2026-09-29-support-finance-order-recovery.md`; Test `tests/business_api/test_openapi_contract.py`, `tests/business_api/test_migrations.py` and `frontend/tests/admin-api.test.mjs`.

- [ ] **Step 1: Red.** 为新路由、严格 body、`expected_preparation_version`/`expected_claim_version`、`REJECTED` 投影、错误 code/message 分离、`no-store` 和普通客服/owner 权限补契约断言；`py -3.12 scripts/export_openapi.py --check` 先报告实际代码与已提交 YAML 不一致，不能靠手改 YAML 蒙混。迁移测试 head 为 0093、旧行兼容、破坏性 downgrade 被拒。更新运行手册，写明“确认开始出款前可取消/拒绝，之后结果未知保持冻结”、人工哈希回退、跨订单歧义、owner 接管、真实历史单只读取证。
- [ ] **Step 2: Green.** 用项目现有导出器生成 `packages/api-contracts/openapi/liuhetong-v1.yaml`，再运行 `py -3.12 scripts/export_openapi.py --check`；检查没有新增任意地址/金额搜索、删除旧错误码或放宽 owner 路由。将 SDK/前端请求与契约字段逐一对齐；在任务台账写 SFO-1 至 SFO-6 的测试文件、证据 SHA、未验证真实会话。
- [ ] **Step 3:** 先专项聚合：

```powershell
$u8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding=$u8; [Console]::OutputEncoding=$u8; $OutputEncoding=$u8
$env:PYTHONUTF8='1'; $env:PYTHONIOENCODING='utf-8'; $env:PYTHONPATH='services/business-api;.'
py -3.12 -m pytest tests/business_api/wallet/test_support_payout.py tests/business_api/wallet/test_support_payout_postgres.py tests/business_api/wallet/test_manual_payout_rate.py tests/business_api/wallet/test_manual_payouts.py tests/business_api/wallet/test_manual_conversions.py tests/business_api/recharge/test_support_order_workflow.py tests/business_api/recharge/test_support_order_http.py tests/business_api/recharge/test_support_order_postgres.py tests/business_api/tron/test_reader.py tests/business_api/wallet/test_support_payout_discovery.py tests/business_api/test_openapi_contract.py tests/business_api/test_migrations.py -q
node --test frontend/tests/admin-support-payouts.test.mjs frontend/tests/admin-recharge-panel.test.mjs frontend/tests/admin-support-orders.test.mjs frontend/tests/admin-support-layout.test.mjs
py -3.12 scripts/export_openapi.py --check
```

  PG 变量必须指向上文两种**本地专用隔离库**；任何 PG skip 都是门禁未满足。按 `docs/runbooks/mobile-delivery-workflow.md` 的变更影响/证据复用规则，先预检 `scripts/verify.ps1` 的 `.env`、Docker、数据库、Node/Python/Flutter SDK、剩余磁盘，条件齐备才运行 `pwsh -NoProfile -File scripts/verify.ps1`；缺失时记录真实 exit code、准确障碍与已通过的独立门禁，不伪称全量通过。
- [ ] **Step 4:** 先做**规格符合性/资金领域**审查，逐项对照 SFO-1–6 和 ADR、账本平衡、回退、历史订单；修复后再做独立**质量/安全**审查，覆盖认证模式、实际 owner、令牌竞争、完整地址、候选歧义、跨订单锁、充值二次入账和接口兼容。检查 `git diff --check`、迁移唯一 head、无密钥/真实钱包地址/敏感日志。绿后提交契约、运行手册和证据。

## Task 14：候选、兼容回退与受控生产发布

**Files:** Update `docs/verification/2026-09-29-support-finance-order-recovery.md` and `docs/workflow/tasks/2026-09-29-support-finance-order-recovery.md`; product files only if gate identifies a defect.

- [ ] **Step 1:** 在发布窗口再次通过 jumper 冻结 API、Worker、全部静态、schema、Compose、配置开关和真正回退镜像 digest；生成最小变更清单、离线备份及 SHA、0092→0093 隔离克隆迁移/恢复和新状态兼容回退证明。若现网迁移 head、API 或钱包静态被其他任务推进，停止切换并重做基线/计划审查。旧 API 不能理解新增在途状态时，回退程序先关闭受影响的提现/充值写入口，保留数据，以兼容镜像或前向修复恢复，绝不删除迁移或直接修改账本。
- [ ] **Step 2:** 按 `docs/runbooks/admin-production-workflow.md` 的候选和镜像门禁顺序发布：先 expand 迁移，候选 API 验证旧页面调用失败关闭和新接口权限，再原子替换明确列出的后台静态，Worker 不改代码则镜像保持原 digest。API/静态间的短窗口不允许旧 `adjust-rate` 再默默开始出款；若旧静态无新版本字段应明确 409，并在新静态到位后恢复入口。生产不创建真实提现、不进行真实 imToken 转账或伪造到账。
- [ ] **Step 3:** 服务器与工作站各自严格 TLS 回读公开 ready、匿名 401/403、OpenAPI 新路由/旧 code、静态真实 SHA；核对 API/Worker 健康、零非预期重启、迁移 head、Outbox/审计写入错误与未结钱包事故。若有已授权真实客服/owner 会话，只对现有订单做只读角色镜像检查：列表禁用、返回、开始前地址脱敏、已开始地址授权与复制、TronGrid 只读发现和接管入口可见性；准备率、拒绝、接管提交与真实资金交互只在隔离测试库或明确授权的安全测试单验证。没有账号或安全测试单时标为待产品验收，不伪称完成。
- [ ] **Step 4:** 按预置兼容路径演练/记录回退触发、静态/API 切换与数据库保留；以实际镜像 digest、命令 exit code、时间、去敏日志和 SHA 更新验证报告、任务台账及 `docs/workflow/current-state.md`。若用户后来提供受影响提现单号，另做只读状态、审计、imToken/链上证据核对，绝不随发布自动解冻或退款。

## 最终完成条件

- SFO-1–6 均有红灯/绿灯、精确代码 commit、契约/迁移、隔离 PostgreSQL 并发和两阶段审查证据；相关专项无新失败，必须门禁满足或如实阻断。
- 生产 API/后台技术验收有真实镜像、schema、静态 SHA、权限拒绝、健康与回退证据；真实客服/owner 交互若不可得单列未验，不把技术发布当作资金处理验收。
- 已发行 Android 只获得服务端中文错误消息；取消按钮过期单显示和失败后刷新仍列入后续 Android 任务，不在本计划误报完成。
