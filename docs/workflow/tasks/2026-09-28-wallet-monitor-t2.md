# 2026-09-28 钱包链源临时不可用 T2

## 恢复入口

- 目标与授权：用户要求解释 2026-09-28 钱包监控异常，将链上数据源暂时不可用降为字面显示的 T2 事故，且不再因该类事件自动暂停钱包。两次澄清限定为这类链源暂时不可用，T2 须直接存储与显示。其他账本、覆盖与储备异常仍按原保护规则。
- 关联决策与计划：[ADR](../../adr/2026-09-28-wallet-monitor-t2.md) · [计划](../../superpowers/plans/2026-09-28-wallet-monitor-t2.md)。
- 当前状态：用户已批准 ADR 与计划；隔离实现、回归、规格/领域/质量安全审查、生产发布和主工作区回填完成。生产目标事故已审计化改为 T2，服务与后台静态验收通过；后续只观察自然故障与用户业务反馈。
- 工作树：C:\Users\Administrator\.codex\worktrees\wallet-monitor-t2\StarChat，基线 b9eca8a419614112b085439445b7fd031027a740，隔离检出。根目录有其他任务的大量未提交改动，不在本任务所有权内。
- 文件所有权：本任务仅处理钱包监控、事故服务/契约、告警消费者、后台事故展示、相关测试及本任务文档；各写入代理不并发编辑同一文件。
- 最后更新时间：2026-09-28 14:35 +08。
- 下一步：保留生产回退快照并观察自然监控运行；若再次出现来源读取预算耗尽，核对 T2、未新增钱包暂停以及资金证据门禁。禁止为验收主动制造生产链源故障。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 缺口 |
| --- | --- | --- | --- | --- | --- |
| WMT2-1 | 解释首次异常与附件事件的各自原因 | 调查完成 | 生产时间线与固定证据 SHA，见下 | 不涉及代码发布 | SQLite 预算耗尽上游是锁等待还是 I/O 目前不能区分 |
| WMT2-2 | 仅已识别的暂时链源读失败记录为 T2，前后端字面显示 | 已实现 | TDD 红绿、API/前端/Worker 定向、OpenAPI；候选镜像导入与公网静态哈希通过，见[验证](../../verification/2026-09-28-wallet-monitor-t2.md) | API、Worker、3 个后台 JS 已发布 | 故障态不在生产主动注入 |
| WMT2-3 | T2 不触发全局暂停、不阻断控制状态；其他 P0 与独立资金新鲜证据门禁保留 | 已实现 | 钱包 1134 passed/20 skipped、领域及安全审查；生产改级前后 3 控制标志均 false | 已发布 | 等自然故障观察 |
| WMT2-4 | 本次已结案事故定向改级，旧审计/Outbox 时间线保留 | 受控命令已执行 | 隔离库 dry-run/apply/replay 与生产 dry-run/apply/replay 均通过；生产审计 1 条、Outbox 已发布 | T2/RESOLVED/g1/v108 | 无 |
| WMT2-5 | 修复来源 360 秒与发布 120 秒不一致，防首次假性 P0 | 已实现 | 120.219 秒健康链源发布、超窗回滚与独立出款 120.219 秒拒绝测试通过；候选源码哈希通过 | 已发布 | 等自然监控观察 |

## 现场证据

- 04:00:46 HKT TronGrid 块头一次 ConnectError；04:00:51 来源仍为 SOURCE_HEALTHY，但 solid head age=120219 ms。来源健康窗口 360 秒，储备发布固定 120 秒，04:00:52 抛出 `reserve evidence stale or future`，归入 MANUAL_MONITOR_UNAVAILABLE，首次自动暂停。
- 04:02:31、04:06:23、04:07:23 HKT SQLite 读取各超过 1 秒预算，归入 MANUAL_SOURCE_UNAVAILABLE。04:02:33 观察器提交 SOURCE_MATCHED。日志未能区分 SQLite 锁等待或 I/O 的上游成因，无余额差异证据。
- 用户附件：1 次 opened、103 次 UNACKNOWLEDGED_P0 升级、1 次 condition_cleared。五分钟重复是同一未确认 P0 的升级，不是每次新故障。
- 两事故 12:53:37 HKT 条件消除并已结案；12:54:20 OWNER_CONTROL_RESUME 审计。末次只读查询时提现暂停、安全限制、储备出款限制均 false。另有 MANUAL_BACKING_DEFICIT P1/ACKNOWLEDGED，为现行 manual_liquidity 策略的非阻断提醒；控制状态 RUNNING 是按代码和 DB 推算，未调用需鉴权 API。
- 最初现场 API 镜像为 sha256:e3043e9a9e8f9f4502e4dde65846f3e8d75fa1eb607d17ab70d5db86c4e1ec8f；并行发布后重定基线 API sha256:261f0425ba69581357038e86e3804be6a596fed8c81af386ab58daa82dc1c07a、Worker sha256:a5087d4724a32298dba37d7dae0cc2b5a9bed9189d2f2dce3be25a36f74a0bf9、schema 0091。9 个 API 目标文件与隔离树原基线逐字节一致。发布仅覆盖目标文件。

## 基线与计时

- `D:\pythonProject\outsource\StarChat\.venv\Scripts\python.exe -m pytest` 定向 8 个钱包/告警测试文件，PYTHONPATH 含 business-api 与 worker：真实 exit 0，143 passed、1 skipped，12.16 秒；Python 3.12.10、SQLAlchemy 2.0.52、coincurve 21.0.0。工作树无 .env；全量 verify.ps1 尚未启动，须先做环境预检。
- 2026-09-28 13:31 +08：API import、OpenAPI `--check`、Alembic 单 head `0087_support_payout_workflow`、`git diff --check` 均通过；工作树 `.env` 不存在，且复制的现行 Worker 入口依赖旧基线所无的 API 模块，全量 `scripts/verify.ps1` 先决环境未满足，不将其记为通过。
- 钱包目录第一轮扩展回归：1119 passed、20 skipped，exit 0；安全复审补改后第二轮 3 项仅因测试夹具试图经已收紧服务注入非法 T2 而失败，其余通过；已改为先写合法事故、再直接变更夹具行验证控制谓词，受影响 4 项通过。最终完整复跑 1134 passed、20 skipped，exit 0，133.39 秒。
- 现场事故 ID `05cc1e53-41d7-4a24-863a-4c81109cafa7`，generation 1/version 107/P0/RESOLVED；诊断与开启事件同 trace，证据文档 SHA-256 `511b56876c2f7a6bf28749a11dd7fa8ff5c84574e41011998c59610f7b3ea8ef`，见[证据](../../verification/2026-09-28-wallet-source-timeout-evidence.json)。生产 schema 为 `0090_friend_discovery_index`（本隔离树单 head 0087，故不能从旧树整建覆盖）。
- 13:45 +08 左右在生产发布前复核发现其他工作同步把 API 镜像从本任务先前冻结的 `e3043e9a…` 切到 `261f0425…`，容器刚重启且仍处于 health starting。立即停止本任务的生产切换/历史写入，改做只读漂移核对；本任务未造成该变更。旧基线候选已废弃，新覆盖包基于 `261f…`。
- 13:57:19 +08 前冻结 Compose、静态文件与镜像；服务器私有目录 `/opt/starchat/releases/wallet-monitor-t2-20260928/private/` 为 0700，数据库备份 29,277,991 B、SHA-256 `a1cc06ada5cfa275762a3165c0abc92c2b8e818298a040aa994e5ccda2f3da73`。隔离 PostgreSQL 16.9 恢复 exit 0，schema 0091、138 表、284652 行，列/索引/363 条约束元信息一致。备份后线上写入使 8 张活跃表自然漂移，未把恢复库当作实时生产快照。
- 14:12:10 +08：在无外网的隔离恢复库内，候选 API 镜像执行历史改级 dry-run、apply、重放读回，得到 P0/v107→T2/v108，未触及生产库。
- 14:14:05 +08 Worker 切到 `sha256:3c9e4bbf4760edd173263efb8a8ad2cbee99af9a287402c4d885f5186eaadaaf`，14:14:29 +08 API 切到 `sha256:c1191a891360c4d3169fa68c7e0973fc2fccee71fe579bae10122a5eb06c3d10`；只重建这两个服务。3 个后台 JS 精确哈希发布。两服务 healthy/restart 0。
- 14:15:56 +08：生产目标事故在受控脚本只读预检 P0/RESOLVED/g1/v107 后审计化改为 T2/RESOLVED/g1/v108；重放读回 ALREADY_APPLIED，3 项限制仍 false；新增审计恰 1 条，新 Outbox 事件 `8a69bf8c-b5f3-4691-9908-05eb26be2728` 已 PUBLISHED/attempt 1。原始 P0 审计/Outbox 由脚本核对未变。
- 发布后服务器公网 HTTPS `health/ready` 返回 JSON ready，事故接口未授权 401，3 个 JS 公网字节哈希与候选相同；工作站经既有 jumper SOCKS 再验 JSON ready/401/JS 200。独立只读复核新 API 7492 行/Worker 39 行日志，ERROR/Traceback/CRITICAL 均 0；发布后新增人工钱包暂停审计 0，活跃 outgoing restriction 为空。
- 主工作区 32 个目标按原哈希守卫回填，31 个源码/测试与候选同字节；OpenAPI 仅在钱包详情/筛选两处加 T2，保留其他并行内容。主目录钱包/Worker 定向 473 passed/1 skipped、前端 378 passed；两个钱包契约字段与生成结果相同。主仓全局 OpenAPI `--check` 仍 exit 1，回填前已复现，属并行契约整文件漂移，不把它冒称通过。回填前后哈希见 `docs/verification/artifacts/2026-09-28/wallet-monitor-t2/source-backfill/`。
- 调查起始时刻：未知（本会话开始未独立取时钟）；文档记录时刻 13:08 +08。主动、工具与外部等待分解待后续按可核对时间补充，不根据文件时间估算。

## 交接与回退

- 不直接改余额、订单、事故旧审计或 Outbox。历史改级须经公开应用服务、真实 actor、幂等键、审计及 Outbox。
- 生产候选 API/Worker Compose SHA-256 分别 `e68162fc1711989cbd6bcf123089c44547f7456ff32c1360145fc72ffd6e0d5a`、`ef55565cd973a538e4d572e3cf05cfcb32fa58c20627239237cf587fa39a0f29`；兼容回退镜像 API `sha256:e6172f5beb3bc0f824d1d08ac0cf1f51f8d942b3d9df71fbd51f5192d74cbb02`、Worker `sha256:4da48d53f49c44f531e473fccb4a32e5d06f8ad116bc2fc5e306cf5a4ff3fb7b`，Compose 分别 `cc70bdaf7227520c540b876e132a35073eb6745688ce8b3a9cfe35bad6ce05f9`、`e04d9a5ec57132c26289f96460b631158ad95e9dbe0839294a0284e5d6e73679`。兼容回退保留 T2 策略，仅恢复旧的储备发布 120 秒阈值，不能用事故改级前旧镜像直接覆盖现行数据语义。
- 前端旧版 3 个 JS 及 `admin.html` 已冻结在服务器私有目录；数据库备份留服务器，演练后的无挂载、无网络隔离恢复容器已停止并移除。临时工作站 SOCKS 隧道已关闭。生产未做余额/订单/资金写入，历史改级命令仅改变事故 severity/version 并写命令、审计及 Outbox。
