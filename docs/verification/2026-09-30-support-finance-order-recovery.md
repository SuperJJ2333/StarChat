# 客服资金订单恢复：实施与发布证据

## 2026-09-30 基线

- 工作树：`C:/Users/Administrator/.codex/worktrees/wallet-ui-polish/StarChat`，分支 `codex/wallet-ui-polish-20260929`；实施前源码 commit `1a246939261b076b25299260875126ab0a987445`，`git status --short` 无输出。
- 用户授权：在书面规格批准后，用户明确要求“修改产品代码和生产环境”。受保护 ADR 与逐项计划按该授权执行，生产发布仍须通过计划中的门禁。
- 本机：PowerShell 7 UTF-8 无 BOM 会话；Python 3.12.10、Node v22.22.2、Docker Server 29.2.1；独立工作树无 `.env`；`scripts/verify.ps1` 存在。启动前无运行容器，也未配置本地专项 PostgreSQL URL；因此建立仅监听 `127.0.0.1:25487` 的临时 `postgres:16.9-alpine` 容器 `starchat-support-recovery-pg`，专用库 `support_payout_review`、`support_order_review`，没有生产连接或数据。前者供测试按随机 schema 自建，后者从空库迁至本地唯一 0092 head。
- 本地 Alembic 唯一 head：`0092_admin_session_entry_mode`。第一次从仓库根调用 `alembic heads` 因迁移路径相对工作目录而失败；改在 `services/business-api` 目录执行得到该 head，未更改配置。
- 基线命令：`py -3.12 -m pytest tests/business_api/wallet/test_support_payout.py tests/business_api/wallet/test_manual_payouts.py tests/business_api/recharge/test_support_order_workflow.py tests/business_api/tron/test_reader.py -q`，退出码 0，`143 passed in 22.83s`。
- 基线命令：`node --test frontend/tests/admin-support-payouts.test.mjs frontend/tests/admin-recharge-panel.test.mjs`，退出码 0，`46 passed, 0 failed`。
- 隔离 PostgreSQL 基线：为两专用库设置 `SUPPORT_PAYOUT_TEST_DATABASE_URL`、`SUPPORT_ORDER_POSTGRES_URL`，运行 `py -3.12 -m pytest tests/business_api/wallet/test_support_payout_postgres.py tests/business_api/recharge/test_support_order_postgres.py -q`，退出码 0，`4 passed in 8.67s`；后续迁移/并发仍需在最终候选重跑。
- 生产只读快照，2026-09-30 00:27:03 +08:00：API 运行镜像 `sha256:fadabb52cd61c078599ceda2544cea6f34dd85b0dbc0b6c5d276c5d3a96ab7dd`，比本工作树前次钱包 UI 发布时的 `83aedc06` 更新；Worker 仍为 `sha256:3c9e4bbf4760edd173263efb8a8ad2cbee99af9a287402c4d885f5186eaadaaf`。两者 healthy、重启 0。生产 Alembic current/head 均为唯一 `0092_admin_session_entry_mode`。生产 payout 核心、客服协调、Tron reader、充值流程的文件 SHA 与本工作树一致；两块提现/充值前端的原始 SHA 不同，经只读逐字节比较，差异仅是本地 CRLF 与生产 LF（分别 106/620 行），代码内容相同。发布清单要明确行尾归一和最终原始 SHA，不能从旧 `83aedc06` 镜像发布。公开 ready 为 200、匿名后台入口为 401；服务器静态与公网严格 TLS 回读一致。当前 Compose 快照 `/opt/starchat/releases/guarded-6rxii8h_/compose.json`（SHA `812ef690…`）；旧回退定义和数据库快照位于 `/opt/starchat/releases/android-2192-api-v4r2-20260929/private/`，钱包工作台旧静态/镜像备份位于 `/opt/starchat/releases/wallet-workspace-20260929-v1/private/`，均只作历史基线，不能代替本次发布前新备份。

## 已开始的红绿循环

- TronGrid reader 原语：先加 13 个发现测试，`py -3.12 -m pytest tests/business_api/tron/test_reader.py -q -k discovery` 因方法不存在而 `13 failed`；实现后 `test_reader.py -q` 为 `60 passed`，相邻 `tests/business_api/tron tests/business_api/wallet/test_tron_finality.py tests/business_api/wallet/test_manual_runtime.py -q` 为 `179 passed`（一条既有 Starlette 弃用警告）。reader 只返回候选 txid，超出固化头或扫描不完整抛错；服务集成必须把它映射成 `INCOMPLETE` 而非“未付款”。独立规格审查无 P0/P1/P2，质量安全审查进行中。
- 0093 expand 迁移红灯：新增测试先于实现运行，`py -3.12 -m pytest tests/business_api/test_migrations.py tests/business_api/wallet/test_support_payout_postgres.py -q` 退出码 1、`5 failed/15 passed`，失败确认为 0093 head/模型字段/触发器缺失；隔离旧行从 0092 升级测试对缺 `prepared_rate` 失败。
- 0093 迁移实现已在 `41200e1ee11071b933b82307729155d9fc0dc2a9` 提交；迁移/隔离 PG/提现协调专项退出码 0，`47 passed in 45.14s`，Alembic 唯一 head 为 `0093_support_finance_order_recovery`。独立规格审查复跑 20 项迁移/PG 与 27 项提现协调，未发现 P0–P2；独立质量安全复核确认原生 SQL 防改触发器、扩展列、版本字段容量与专用本地数据库隔离，未发现 P0–P2。
- 独立数据库备份/恢复演练：在仅监听本机的临时 PostgreSQL 中，对已经迁至 0092 的 `support_order_review` 执行 `pg_dump -Fc`，将归档恢复至新 `support_order_rehearsal`，恢复后的 `alembic_version` 为 0092；再对此恢复库执行 `alembic upgrade head`，退出码 0，`alembic current` 为 0093。原 0092 库保持不变；该演练不包含生产数据，也不能替代发布窗口对生产备份的恢复验证。
- Tron reader 满页复审缺口：质量审查复现 200 条满页却没有游标时错误返回完整；新增用例先以 `DID NOT RAISE` 失败，修复后仅发现模式抛 `TronReadError`，旧 `snapshot()` 行为保持。reader 专项独立复跑 `62 passed in 3.24s`，提交 `45acdc2e3e1519bd46115b216705cbefabdb2529`；独立复审确认满页失败关闭、旧快照不变、测试可检测回归，P1 已关闭。
- Task 3 账本释放接口：实现者先以 3 项用例证明缺少公开释放/实际操作者接口及准备值清理，修复后六组钱包/账本、客服和隔离 PG 聚合 `134 passed`，初始提交 `7b7b32d5674747968468492cfba685894559a243`。实现者事后自审发现底层兑换冲正重放未重核 release 关联，新增用例以 `DID NOT RAISE` 失败，补充提交 `a575c53ab38f2c6ee38a572eca1a0a3aaa444dee` 后聚合 `135 passed`；独立规格/资金与质量安全审查进行中。
- Task 4 暂存汇率与原子开始：`8a76ad29`；准备版本、历史已开始点钻单、零汇率篡改、旧调整入口、目标绑定漂移均先得到预期红灯，再修复；提现/账本/隔离 PG 152 项通过，三个 PG 并发竞态通过。独立规格/资金及质量安全复核未发现 P0–P2；独立检查时另有 Task 5 尚在红灯的用例，不计为 Task 4 失败。
- Task 5 拒绝与旧 Android 中文消息：`17fcb2b`；实际客服为账本操作者，核心终态兼容 `CANCELLED`、客服投影 `REJECTED`，释放原 `HOLD` 与链接兑换，原因、幂等、审计及 Outbox 同事务；取消/拒绝/开始三方 PG 竞态仅一方获胜。独立复核发现释放中的等待可能跨过认领租约，先加失败用例，再于 `67ac473a` 提交最终认领复核；提现/隔离 PG 专项 56 项通过。共享 owner 当次证明依赖由 `a3d18d30` 一并提交；Task 5 最终独立复核待收尾。
- Task 6 完整地址边界：`f72ef2d`；客服列表、详情及开始响应只返回脱敏目标，开始后经单独 `payment-address/read` 读取完整地址，成功读取记审计/Outbox、响应 `no-store`，旧证据人和配置 owner 在实时授权范围内可读；133 项提现/隔离 PG 定向测试通过。独立复核进行中。
- Task 11 提现前端初版：`cf3cd446`，DOM/API/布局聚合 80 项通过。独立审查指出 403 刷新后敏感地址未清、owner 拒绝缺当次证明、拒绝终态文案、焦点回归及暂存金额显示缺口；实施者正在加失败用例修补，初版尚未通过最终审查。CUA 浏览器本机不可用，真实浏览器视觉验收须在可用环境补做。
- Task 10 充值受控接管及共用新鲜证明：`a3d18d30`。预填哈希初领、本人续领、他人租约过期仍有资金证据、旧收据超 120 秒及订单超时、活动绑定、角色撤销、旧令牌与选定验证模式分别先红后绿。独立公开钱包接口只证明旧收据归属以移交令牌，不取消结算时 120 秒复验。充值 HTTP、工作流、隔离 PG、钱包收据与身份授权合计 `91 passed`（1 条现有警告）；`py_compile` 和差异检查通过。独立领域/安全复核正在进行，未发布。

## 实施门禁

- 隔离 PostgreSQL 迁移/并发/资金验证：本地专库已完成 0092→0093 恢复演练及当前专项；最终候选仍需集成复跑。
- 红灯/绿灯证据已有上述阶段记录；链上服务集成、跨订单归属、前端修补、OpenAPI、最终领域/安全审查与完整验证待完成。
- 候选与兼容回退镜像、真实 Compose 与续期协议、生产发布及公网检查：待执行。
- 历史已开始订单：不自动退款或回拨；没有用户提供的具体订单号，不进行单笔资金操作。

## Root Task10 安全返工验证

`5988f219`：TOTP 验证返回不可变 credential identity/digest/step/time，当次动作终检拒绝凭据替换；充值接管响应 no-store，精确已完成重放先返回仍有效旧收据；能力投影经公开只读接口验证 receipt 归属/金额/txid/未消费。真实凭据替换测试 RED→GREEN，接管 replay RED403→GREEN200。隔离 PG enabled 聚合 47 passed/45.99s：fresh-owner-proof、workflow、support-order-postgres、support-recharge-receipts、rbac-totp、binding-adapters。独立 scoped review 进行中。

完整 verify 实际运行 exit1：三个 policy/template gate 通过，render-only 缺 `.env` 停止。Docker Desktop 恢复并启动既有专用 PG，非生产数据库。2026-09-30 再次只读生产镜像 API fadabb52/Worker3c9e4、running/0 restart。尚无本轮生产发布。

## Tasks7–9 / 前端返工

`c03737b0` payout discovery/selection/final attribution/takeover 完成。269 focused passed，后续20 discovery/takeover及16 discovery passed；隔离PG12 passed58.89s、变更增量4 passed17.55s。独立 scoped spec/domain then quality/security PASS，无P0–P2；最终 backend integration review 进行中。

`64305b86` 前端复审五项P1统一修复，额外未知候选不可选择及真实 evidence_token 响应断言；先6个失败，后79 focused/source tests PASS。前端 scoped re-review 进行中，候选尚未部署。

## 最终源码审查及生产准备（2026-09-30 06:51 UTC）

最终frontend64305、payoutc037/ec1、finance4f17/c4c、生产rebase479及工具c204均完成独立规格/领域与质量安全审查，无P0–P2待修。独立121 finance专项、12VOID、22迁移+5OpenAPI通过；root新0094 PG31/9.24s和发现/maintenance31/5.79s通过。完整API/Worker门禁保留真实结果：3276pass/73skip/6fail/1warning，2496.21s；6个失败由最终聚焦测试逐项关闭，无重复全量或假称最初exit0。

生产新基线API902eaefc/Worker90d7fb74/schema0093_void已按不可变源码完整核对并保留；0094扩展不替换0093。最终archiveSHA9f4ba401…、manifestSHA42ad9a8e…，sourcec204；06:51:05 UTC实时snapshot+服务器preflightPASS。prepare私有备份PASS，备份SHA d76ea343…，其余28容器冻结。数据备份留服务器0700目录未下载。

build在构建前因actualAPI启动直接uvicorn（无alembic）安全停止。尚未构建候选或切换服务/迁移生产schema。修订工具将先切真实fencedAPI再单次dockerexec扩展，保持Cmd/Compose，补红绿与独立审查后按SHA原子替换工具再恢复执行。真实管理员会话及金融实际操作验收仍待，历史已开始单不自动退款。

## V2 准备与源 Compose 门禁（2026-09-30）

- 46e38c8d 独立审查PASS；只替换clone_recovery.py，SHA b740ad0c701887e00818888a73ea02010ad5e20d25e39d5ce4ebce8116bd308a。cleanup-only成功删除记录中的隔离clone9bffed…及匿名卷b4b77e…，保留v1私有失败日志/原manifest与baseline；无restore、无生产改动。
- V2 source仍c204d415；manifestSHA c32fe3b6b8de5c8ee1937e00167418db43da3f8a835e61cdd4554f3fc7847d12，archiveSHA 9b8861c879bcc7275f207f41816d06d79fa55ae4f445d4b69f2d1fbf248bafd0；上传严格校验PASS。
- V2 preflight在prepare之前拒绝：API源Compose含旧Workerpeer，而当前Worker已单独发布00c。没有创建私有备份、构建、迁移或切换。本轮前述072dd仅修派生candidate/rollback，源baseline读取仍错误地要求两个历史源中的peer相同。
- Ruling：每个实际容器标签绑定的源Compose只以所属service为权威，精确SHA与所属live镜像/Env继续核对；完整合并baseline由两个所属角色派生并严格核对，不把旧peer当现状。必须TDD/独立领域及安全审查，通过后只SHA门禁替换工具；产品manifest/payload不变。成本是多一轮发布工具修订，不能牺牲实际配置检查绕过门禁。
