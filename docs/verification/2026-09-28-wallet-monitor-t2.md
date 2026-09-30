# 2026-09-28 钱包链源读取超时 T2：验证记录

## 目标、基线与审批

用户限定：仅已识别的链源读取预算耗尽记录为字面 `T2`，不因该事件自动暂停钱包。用户已批准[ADR](../adr/2026-09-28-wallet-monitor-t2.md)和[实施计划](../superpowers/plans/2026-09-28-wallet-monitor-t2.md)，其中包括修复已证实的储备发布 120/360 秒错配、保留出款独立 120 秒门槛，以及对本次历史事故审计化改级。

隔离工作树为 `C:\Users\Administrator\.codex\worktrees\wallet-monitor-t2\StarChat`，基线提交 `b9eca8a419614112b085439445b7fd031027a740`。主工作区有其他任务未提交改动，未用整树覆盖生产。执行环境为 PowerShell 7、Python 3.12.10（`D:\pythonProject\outsource\StarChat\.venv\Scripts\python.exe`）、SQLAlchemy 2.0.52；每次命令设置 UTF-8 无 BOM 与 `PYTHONUTF8=1`、`PYTHONIOENCODING=utf-8`。

## 现场原因

- 04:00:46 香港时间有一次 TronGrid 区块头连接错误。04:00:51 观察源仍报告健康，但固化区块年龄 120.219 秒；观察源窗口 360 秒，储备发布硬编码 120 秒，04:00:52 抛 `reserve evidence stale or future`，归类 `MANUAL_MONITOR_UNAVAILABLE`，这是首次自动暂停。
- 04:02:31、04:06:23、04:07:23 三次 SQLite 观察源读取超过 1 秒预算，诊断 `SOURCE_READ_BUDGET_EXPIRED`，归类 `MANUAL_SOURCE_UNAVAILABLE` 并曾引发后续暂停。04:02:33 观察器报告 `SOURCE_MATCHED`。预算耗尽的更上游原因（锁等待或 I/O）不能从现有证据确定。
- 附件中 103 次 `UNACKNOWLEDGED_P0` 是同一事故每五分钟左右的升级提醒，不代表 103 次新故障。现场只读时两起事故已结案，12:54:20 有独立拥有者恢复审计；控制标志为未暂停/未限制。生产读回须在发布前重新执行。

## 测试先行与结果

本轮先证实固定 120 秒拒绝仍处于 360 秒健康窗口的签名观察，精确读取预算异常会 P0/暂停，T2 枚举与历史命令未实现，任意事故可被写为 T2，存储错误可被预算异常掩盖，重采样截止可把格式错误记为 P1。对应测试在修改前按预期失败；修改后均转绿。

| 门禁 | 结果 |
| --- | --- |
| 原始 8 文件钱包/告警基线 | exit 0；143 passed、1 skipped，12.16 秒 |
| 监控、重采样、储备发布、出款、恢复 5 文件 | exit 0；210 passed，19.15 秒 |
| 事故、底层预算、监控、重采样、恢复 5 文件（安全返工后） | exit 0；139 passed、1 skipped，14.43 秒 |
| 非预算源错误及 T2 下收据/出款证据不可用反例 | exit 0；7 passed，1.64 秒 |
| 钱包目录首轮扩展回归（安全返工前） | exit 0；1119 passed、20 skipped，114.06 秒 |
| 钱包目录第二轮（收紧 T2 输入后） | 3 项旧测试夹具绕过服务边界失败；其余通过。将夹具改为先写精确合法 T2 再直接模拟持久行漂移，受影响 4 项 exit 0。最终扩展回归另行记录。 |
| 钱包目录最终扩展回归（夹具修正后） | exit 0；1134 passed、20 skipped、1 个现存 Starlette 弃用提醒，133.39 秒 |
| 事故/控制/报表/API/OpenAPI/告警定向 | exit 0；108 passed、1 个 PostgreSQL 条件跳过；后续审计 trace 哈希修改另有 5 项通过 |
| Worker 投递与 SMTP 定向 | 7 个内部发布、2 个 producer catalog、42 个告警邮件用例通过；Python 编译及 diff 检查通过 |
| `npm test --prefix frontend` | exit 0；303/303 passed；静态入口两级 import URL 已更新 |
| API 导入、`scripts/export_openapi.py --check`、`alembic heads`、`git diff --check` | 均通过；迁移 head 为 `0087_support_payout_workflow`，本任务无迁移 |

钱包目录测试使用 `PYTHONPATH=<worktree>/services/business-api;<worktree>/services/business-worker/app`。底层、事故和 API 定向测试使用 `PYTHONPATH=<worktree>/services/business-api`。完整 `scripts/verify.ps1` 未执行：隔离工作树没有 `.env`，脚本依赖本机全局 `py -3.12` 和完整 Worker/API 同版源码；当前 Worker 入口来自生产对应版本，旧基线缺其 `media_blob_storage` 和内部发布常量。直接跑完整 Worker 内部发布套件在旧树产生 67 个导入失败、10 个通过，不能算生产候选失败或通过。候选须在冻结生产底座覆盖目标文件后单独导入、启动及回放验证。

## 审查与财务边界

规格审查确认精确分类、字面 T2、告警/后台契约、360 秒发布窗口与独立 120 秒出款门槛符合获批决策。领域审查确认 T2 不解除既有暂停。质量/安全审查提出三项代码问题，已加红绿用例修正：事故服务只接受精确身份的 T2；SQLite 被进度处理器明确中断才标预算耗尽，其余格式/存储错误继续 P0；重采样截止同时遇到非预算异常仍 P0。修正后相关 139 passed/1 skipped，另有资金证据反例 7 passed。

T2 不发布新的储备。仍在 120 秒内的旧储备可通过原有出款申请/领取门槛；这不等于结算证据。收据入账与出款结算在最终性证据不可用/过期时仍拒绝，测试明确在 T2 且未全局暂停的状态下验证无新收据或结算分录。此前已存在的暂停和资金限制不因 T2 消除。

## 生产证据与发布

历史改级命令在代码中要求精确事故身份、generation、version、诊断字符串、真实证据 SHA-256、操作者及幂等键。只读现场证据已整理为[独立文档](2026-09-28-wallet-source-timeout-evidence.json)，SHA-256 `511b56876c2f7a6bf28749a11dd7fa8ff5c84574e41011998c59610f7b3ea8ef`：源失败日志和事故提交共用 trace，指向目标事故同一 generation；生产源码该栈末端独占抛出 `SOURCE_READ_BUDGET_EXPIRED`。不得用测试中占位摘要在生产执行。命令没有公开 API 路由；执行前后须核对实际已认证运维身份与审计/Outbox。

05:30 UTC 首轮只读现场为 API 镜像 `sha256:e3043e9a9e8f9f4502e4dde65846f3e8d75fa1eb607d17ab70d5db86c4e1ec8f`、Worker 镜像 `sha256:a5087d4724a32298dba37d7dae0cc2b5a9bed9189d2f2dce3be25a36f74a0bf9`、schema head `0090_friend_discovery_index`。目标事故 ID `05cc1e53-41d7-4a24-863a-4c81109cafa7` 为 P0/RESOLVED/generation 1/version 107；暂停、安全和储备出款限制均为 false。运行配置 `BUSINESS_WALLET_REAL_FUNDS_ENABLED=false` 原样保留。9 个修改的 API 文件在运行 API 和 Worker 内嵌源码中均与本工作树原基线同 SHA；Worker 实际从 `site-packages/app` 导入这些模块，候选必须同时覆盖安装目录和内嵌源码。后台 `admin-home.js` 与面板线上版本匹配当前主工作区而不同于隔离基线，静态候选须做精确增量合并。尚未构建/切换候选、执行历史命令或修改生产数据。

05:45 UTC 另一发布将 API 镜像切为 `sha256:261f0425ba69581357038e86e3804be6a596fed8c81af386ab58daa82dc1c07a`、schema 切为 `0091_moment_video_posters`。本任务停止写入并复核；05:49 UTC 两服务均健康，9 个目标 API 文件仍与本工作树原基线字节相同，Worker 与目标事故版本及三项控制状态未变化。旧 API 底座的覆盖包废弃；新底座的[覆盖归档](artifacts/2026-09-28/wallet-monitor-t2/wallet-monitor-t2-server-overlay.tar.gz)逐项核对 20 个文件，SHA-256 `47a0a6ff584e5c6be51d42cf81f98c970659a8560264219c690c04f0896e3df5`。前端 3 个候选 JS 从现行线上对应源码增量合并，见[静态清单](artifacts/2026-09-28/wallet-monitor-t2/frontend-merged/MANIFEST.md)；暂存内容语法与 62 个定向用例通过。

05:57:19 UTC 完成生产备份与隔离恢复：服务器私有目录 `/opt/starchat/releases/wallet-monitor-t2-20260928/private/` 权限 0700，PostgreSQL 归档 29,277,991 字节、SHA-256 `a1cc06ada5cfa275762a3165c0abc92c2b8e818298a040aa994e5ccda2f3da73`。无网络 PostgreSQL 16.9 克隆恢复 exit 0、head `0091_moment_video_posters`、138 表、284652 行；列、索引、363 条约束元信息完全一致。备份后线上监控/审计继续写入，故 8 张活跃表在后续只读快照中变化，不声称活库零漂移。静态旧文件与原 Compose、镜像检查结果一并冻结。

候选包在服务器校验 SHA-256 与两个文件清单后，用禁网、不拉取远端的 Docker 构建出 API `sha256:c1191a891360c4d3169fa68c7e0973fc2fccee71fe579bae10122a5eb06c3d10`、Worker `sha256:3c9e4bbf4760edd173263efb8a8ad2cbee99af9a287402c4d885f5186eaadaaf`。兼容回退分别为 `sha256:e6172f5beb3bc0f824d1d08ac0cf1f51f8d942b3d9df71fbd51f5192d74cbb02`、`sha256:4da48d53f49c44f531e473fccb4a32e5d06f8ad116bc2fc5e306cf5a4ff3fb7b`，只省去 360 秒储备发布修正，保留 T2 契约。4 个镜像均通过禁网容器内导入、目标文件哈希及事件目录检查。Compose 候选仅替换对应服务镜像，`docker compose config --quiet` 通过；候选 API/Worker JSON SHA 分别为 `e68162fc1711989cbd6bcf123089c44547f7456ff32c1360145fc72ffd6e0d5a`、`ef55565cd973a538e4d572e3cf05cfcb32fa58c20627239237cf587fa39a0f29`。

[受控操作脚本](artifacts/2026-09-28/wallet-monitor-t2/operator-reclassify.py)经独立审查补全重放摘要/结果校验，SHA-256 `b9100e94a1667f01f59f3ec7931aafad4d24ab05a61d3d8d3390c2932638daa0`；本地 SQLite 6 项与 2 项篡改重放检查通过。在隔离恢复库中以候选 API 镜像执行 dry-run 得 P0/RESOLVED/g1/v107，06:12:10 UTC apply 得 T2/v108，重放读回 ALREADY_APPLIED，未连接生产数据库。随后生产现场再核对 API/Worker/Compose/静态文件/schema、目标 P0/v107 及三项限制 false。

06:14:05 UTC 仅重建 Worker，06:14:29 UTC 仅重建 API；两个容器分别使用上述候选 digest，健康检查 `healthy`、重启次数 0。3 个后台 JS 原子替换并经服务器与公网哈希核对：`admin-home.js` 为 `98438108d3113c89e730175c49c81bd14c182cea4054823f6197a8700670bb7c`，`admin-manual-wallet-panel.js` 为 `45a9f02ae3662a0f89ed7dc1ac00ffb811f82b65761c244a2303d42f4860d5f8`，`wallet-incident-workflow.js` 为 `e03f1fe9fd245a10bff6ec5d7095d71e1424d5b15cffe2ae9a82ccf3dbe11575`。

生产 API 容器先以固定证据和脚本只读预检 P0/RESOLVED/g1/v107，06:15:56 UTC 通过应用服务事务 apply，读回 T2/RESOLVED/g1/v108，再读为 ALREADY_APPLIED。脚本确认原 P0 审计/Outbox 内容未变，新增审计仅 1 条，控制快照完全相同。新 Outbox 事件 `8a69bf8c-b5f3-4691-9908-05eb26be2728` 状态 `PUBLISHED`、attempt 1；钱包提现暂停、安全限制、储备出款限制仍均 false。没有迁移、余额/订单或真实资金写入；既有 `BUSINESS_WALLET_REAL_FUNDS_ENABLED=false` 未改。

服务器公网 HTTPS `GET /api/v1/health/ready` 返回 JSON `ok=true/database=ready`，无凭据事故接口返回 401，三个静态 JS 的公网字节 SHA 与候选一致。工作站通过临时 jumper SOCKS 再验 JSON ready、401、后台 JS 200，隧道已关闭。发布后 API/Worker 日志 ERROR/Traceback/CRITICAL 计数 0，两个容器 healthy/restart 0；网关与数据库容器持续运行。演练后的无挂载、无网络隔离恢复容器已停止并移除，服务器数据库备份保留。真实链源故障不在生产主动注入；自然再现时继续观察 T2 与不新增自动暂停。完整 `scripts/verify.ps1` 因上述隔离基线环境缺口未记为通过。

独立只读复核再次确认 0091 唯一 head、目标事故非活跃且 T2/v108、历史 P0 开单审计及 Outbox 保留、纠正事件 PUBLISHED、活跃 outgoing restriction 为空，06:14 UTC 发布后新增人工钱包暂停审计 0。对新 API 7,492 行与 Worker 39 行日志逐词检查，`ERROR`/`Traceback`/`CRITICAL` 均为 0；一次 PowerShell→SSH 的宽泛 grep 转义误计已由直接读日志排除。API 容器内的临时操作脚本与证据副本已移除，服务器私有归档保留。以上只说明发布后的观察窗口；不会为验收主动制造链源故障。

## 主工作区回填

生产发布后按原 SHA 守卫把 32 个钱包源码、测试和契约目标回填到主工作区；31 个源码/测试字节与隔离候选相同。OpenAPI 主文件此前已含其他并行 API 变更，仅精确合并钱包事故详情与筛选参数的两处 `P0/P1/T2` 枚举，保留其他内容。逐文件原/后哈希见[回填前](artifacts/2026-09-28/wallet-monitor-t2/source-backfill/preflight.json)与[回填后](artifacts/2026-09-28/wallet-monitor-t2/source-backfill/postflight.json)。主工作区钱包/Worker 定向测试 473 passed、1 skipped、exit 0；前端全量 378 passed、exit 0；两个钱包 T2 契约字段与当前生成结果一致，scoped `git diff --check` exit 0。全局 `scripts/export_openapi.py --check` 与 OpenAPI contract 的 1 项全文件一致性测试仍失败，且在回填前已复现；这属于主工作区并行 API 契约整体漂移，本任务没有用整份重生覆盖其他任务的未完成契约。未据此声称主仓全局门禁全绿。
