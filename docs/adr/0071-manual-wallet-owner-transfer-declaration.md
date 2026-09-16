# ADR-0071：官方钱包所有者转出申报（owner transfer declaration）

日期：2026-09-15。状态：已批准（用户 2026-09-15 明确确认后启动；实现须通过领域与质量/安全审查及测试门禁后方可发布）。

## 背景

2026-09-15 17:34:12（香港时间）官方钱包持有者从官方地址向一个非用户地址转出 2.00 USDT（txid `79bb6d7c82e137ed0b393923bb2fb815d3060aeafcd367949836122c96fa0b81`，log_index 0）。人工钱包监控在 94 秒后的下一轮扫描中正确识别该支出无对应出款订单，按 `MANUAL_UNALLOCATED_OUTFLOW` 熔断暂停提现（事故 9a494b09）。持有者确认该转出为其本人操作的测试/对外付款，但现有产品没有任何通道可以记录这类支出：

- 出款订单只能由用户发起（绑定地址 → 报价 → 订单），管理端无任意地址出款入口；
- `PayoutReconciliationService` 只能对已认领的既有订单补挂历史 txid 证据；
- 因此该链上支出永远无法通过对账复核，钱包无法恢复——这是对账设计的缺口，不是检查的过错。

"每笔官方钱包链上支出必须可解释"的底线保持不变；缺的是把"持有者自主转出"从不可解释状态变为受控已记录状态的合法路径。

## 决策

1. 新增不可变申报表 `wallet_manual_owner_transfers`（expand-only 迁移，新 head）：每行记录 txid、log_index、收款地址、金额（USDT，两位以内小数、六位精度存储）、原因码、原因说明、申报操作者、所有权声明摘要与申报时间；`(txid, log_index)` 唯一，禁止删除或修改，纠错只能追加关联冲正。
2. 新增受控申报服务：仅官方钱包持有人管理员（`wallet_manual_owner_admin_id`）可调用；要求独立操作密码授权（与 deposit repairs 相同的 `_authorize`/commit_check 管道）、可信时钟、链上实时证据（TronGrid `transaction_evidence`，新鲜度校验）、且该支出已作为 VERIFIED 覆盖事实存在、未被任何出款事件占用。预览与执行分离；执行在同一事务内写入申报行、平衡账本分录、审计事件与 Outbox 事件，并按固定幂等键可重放。
3. 账本处理：申报产生一笔平衡的 USDT 钱包账本事务（`PLATFORM_CUSTODY` +金额、`PLATFORM_OWNER_DRAWING` −金额），`PLATFORM_OWNER_DRAWING` 计入负债排除清单（与 `PLATFORM_CUSTODY`、`PLATFORM_CONVERSION` 同级），因此用户负债与可赎回负债不受申报影响；钱包账本继续与链上余额可对账。储备充足性检查（`MANUAL_RESERVE_DEFICIT`）不受申报影响——申报解释资金去向，不掩盖资金缺口。
4. 监控扩展（唯一放宽点，范围最小）：`_coverage` 的支出分支在既有出款订单校验之外，增加"匹配到已申报所有者转出"的接受路径；匹配条件为 txid、log_index、金额（精确十进制）、收款地址与申报行完全一致。任何字段不一致仍返回 `MANUAL_UNALLOCATED_OUTFLOW`。暂停、复核、结案、恢复资金、180 秒新鲜度等全部既有语义不变。
5. 接口与配置：新增独立管理路由 `/wallet/manual/owner-transfers`（preview/execute/status），受新开关 `wallet_owner_transfers_enabled`（默认关闭）与 `wallet_real_mode=manual_tron`、访问授权、独立操作密码多重门禁；生产开启需显式设置环境变量。管理面板提供申报入口与预览-确认两步操作。
6. 不改动：出款订单状态机、用户提现流程、暂停/恢复核验、新鲜度上限、覆盖事实写入路径、E2EE/RBAC/TOTP/审批/幂等/对账/审计检查；不新增 USDT P2P 或红包；不追溯处理本次 txid 之外的任何历史支出。

## 后果

- 持有人自主转出从此必须在系统内申报留痕；未申报的转出仍会熔断钱包，语义与今日一致。
- 复核恢复路径（申报 → 对账通过 → 复核 → 结案 → 恢复资金）成为此类事故的唯一合法出口；runbook 同步更新。
- 账本新增账户命名空间 `PLATFORM_OWNER_DRAWING`；财务报表如按账户聚合需知悉该账户语义（所有者权益性流出，非负债）。

## 实施记录

2026-09-15 实现完成（未部署）。测试先行：11 项领域测试先红（8 项服务缺失 ERROR、2 项断言 FAILED）后绿，覆盖申报放行对账、未申报仍阻断、幂等重放/冲突、非持有人拒绝、声明缺失拒绝、不可信时钟拒绝、log_index 不符、已被出款事件占用、覆盖事实缺失、负债排除。`tests/business_api`+`tests/business_worker` 全量 1922 通过 / 58 跳过；钱包套件 989 通过。OpenAPI 契约已重新导出；迁移 head 断言更新为 `0067_wallet_owner_transfers`。管理面板新增「所有者转出申报」区（钱包访问授权可见），前端 127 项测试通过。生产发布前置条件：迁移 0067 + API 环境 `WALLET_OWNER_TRANSFERS_ENABLED=true`；发布需按 ADR 要求完成领域与质量/安全审查签署。

2026-09-15 生产发布（用户批准并指示执行）。按 `docs/runbooks/admin-production-workflow.md` 最小覆盖模式：候选镜像基于在线镜像 `f1c9d1eb…`(API)/`a1a646f4…`(worker) 逐文件叠加，经基线 diff 证实 API 侧差异仅含本 ADR 变更；worker 共享模块存在其他未部署差异，按"生产文件+仅本次 hunk"外科合并（monitor 整文件、safety/service 定点替换、新模型文件）。发布记录与证据存于服务器 `/opt/starchat/releases/adr0071-owner-transfer-20260915/`（0700）：frozen 配置、基线备份、`liuhetong-pre-adr0071-20260915T154816Z.dump`、candidate 门禁、`deployment-complete.json`。生产切换前完成隔离 PG16 演练（迁移链 0001→0067、不可变触发器、API 就绪、未授权 401、worker 导入）。切换后 postcheck：就绪、9+5 文件哈希与清单一致、开关生效、worker 心跳推进、钱包暂停状态未变、无关容器未变。公网验收（jumper SOCKS+TLS）：健康 JSON、未授权 preview 401、admin 域两文件 SHA256 与清单一致。`WALLET_OWNER_TRANSFERS_ENABLED=true` 仅开启 API；worker 未加（无需）。首次实际申报由持有人管理员在面板执行。

2026-09-16 r2 修正：首次申报后复核结案仍被反复重开。根因——worker 主进程（cwd `/opt/business-worker/app`）的 `app` 导入解析到 site-packages 的 pip 安装副本，r1 只叠加了 `/opt/business-api`，旧监控在 worker 运行时持续以 MANUAL_UNALLOCATED_OUTFLOW 重开事故；API 复核用新代码故每次通过。修正：r2 候选基于 r1 镜像把四个文件同样叠加到 `/usr/local/lib/python3.12/site-packages/app/modules/wallet/`，演练改为忠实还原真实运行时（无 PYTHONPATH 覆盖）并断言 `_owner_transfer_declared` 存在。切换后监控状态 BLOCKED→WAITING（申报被对账接受），12 分钟零阻断。教训入册：镜像内多份代码副本时，冒烟必须按真实进程的 cwd/PYTHONPATH 断言行为而非仅 import。运行性遗留：worker alert 分发器对 3 个非告警主题的 PENDING 事件（2× ledger.outgoing_restricted、1× moment.commented，均产生于阻断循环期间）持续报 dead-letter 提示；该 DEAD 池累计 39,776 条属既有平台运维事项，需按 outbox 重放工具核对，其中 moment.commented 涉及一条用户通知可能未送达。
