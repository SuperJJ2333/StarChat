# 客服提现处理、链上核验与独占认领修复

## 恢复入口

- 目标、用户授权与边界：用户报告提现取消出现 `Wallet_payout_cannot_cancel`、客服确认汇率后无法返回/复制客户地址/拒绝订单、无哈希链上查询不可用、他人认领的提现或充值单仍可点处理。用户已选定“确认开始出款前可取消及拒绝”、无哈希 TronGrid 候选发现并人工选择、官方钱包所有者管理员经单独确认审计接管、弹窗返回列表且出款前可重调汇率。独立资金审查后，用户另批准安全修订：调汇率只暂存待执行值，不改变冻结；真正开始出款时原子调整冻结且此后才开放完整地址与复制。本轮仅后台与 API，Android 新包后续交付；旧版 Android 的原始错误消息由 API 兼容中文化。历史已开始订单仅只读核查，不自动退款。
- 关联规格：[本轮书面规格](../../superpowers/specs/2026-09-29-support-finance-order-recovery-design.md)已获用户批准；用户于 2026-09-30 明确要求“修改产品代码和生产环境”，按[受保护 ADR](../../adr/2026-09-29-support-finance-order-recovery.md)与[逐项实施计划](../../superpowers/plans/2026-09-29-support-finance-order-recovery.md)执行及受控发布。[原人工出款 ADR](../../adr/0013-trongrid-single-source-manual-payout.md)、[客服订单原规格](../../superpowers/specs/2026-09-23-support-order-workflow-design.md)继续约束链上与资金事实。
- 当前状态：根因只读调查及 ADR/计划预审完成，用户已批准实施和受控生产发布。2026-09-30 00:22 +08:00 开始环境与现网基线；基线时尚未修改可执行代码、发布 API/后台或操作资金。
- 负责人、工作树、文件所有权、源码 commit：主代理独占 ADR、计划、任务记录、验证报告及总体整合；`prod_baseline` 只读现网、`tron_reader_impl` 独占 Tron reader/专项测试、`migration_impl` 独占 0093 迁移/模型/专项测试。工作树 `C:/Users/Administrator/.codex/worktrees/wallet-ui-polish/StarChat`，本次代码实施基线 `1a246939261b076b25299260875126ab0a987445`，开始时 `git status --porcelain` 为空；D 主目录另有其他任务未提交内容，不在本任务修改。
- 最后更新时间（含时区）：2026-09-30 00:30 +08:00。
- 下一条具体操作、必要输入、阻断的验收 ID：完成 Task 1 生产只读基线和测试记录，确认生产 schema/镜像无漂移后从 Task 2 expand 迁移开始。用户若提供受影响提现单号，只读核查该订单的真实开始、候选、审计与链上状态；在证据足够前不对旧单执行退款或拒绝。SFO-1 至 SFO-6 尚待实施和验收。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| SFO-1 | 真正开始出款前取消或拒绝；冻结、点钻兑换和差额安全冲正 | 已实施；最终审查中 | 已定位早启动根因；需红绿及隔离 PostgreSQL 并发/账本验证 | 未发布 | 现有已开始单另行核查 |
| SFO-2 | 汇率可再调、弹窗返回、客户地址突出及完整复制 | 已实施；最终审查中 | 已定位返回和地址只存在于 begin 响应的缺陷；需 DOM/权限测试 | 未发布 | 真实后台会话待验 |
| SFO-3 | 无哈希 TronGrid 候选发现与固化收据核验 | 已实施；最终审查中 | 已定位当前 reconcile 仅遍历已存候选；需分页、歧义及账本不变测试 | 未发布 | 真实链上查询待验 |
| SFO-4 | 他人认领时普通客服入口禁用，提现与充值一致 | 已实施；最终审查中 | 现有前端 46/46 测试通过但无该断言；需新失败用例 | 未发布 | 真实双客服会话待验 |
| SFO-5 | 仅官方钱包所有者管理员受控接管，旧令牌失效、已开始仅证据核对 | 已实施；最终审查中 | 服务端当前无接管例外；需权限/竞态/重复付款测试 | 未发布 | 真实管理员会话待验 |
| SFO-6 | 受控 API/静态发布、旧 Android 中文兼容及历史单隔离 | 已实施；最终审查中 | 当前生产后端关键模块与基线一致；发布前仍须重新冻结镜像、schema、静态与回退 | 未发布 | Android UI 改动明确后续版本 |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源 commit | 包名/签名渠道 | 文件位置及 SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| 当前 Android 正式包 | `0.4.24+2193`；本轮不重建 | 前轮 Android 2193 发布记录位于独立工作树 `withdrawal-quote-policy`；本工作树发布前须重新核实 | `com.liuhetong.mobile` 固定签名 | 前轮 APK SHA `8ea9eafb95bcf07c5655266d3eb71766c5799ba364103b23004820f3cf4e6dec` | 前轮已发布；本轮无 Android 包 |
| 当前钱包/客服后端 | 2026-09-30 00:27 +08:00 生产 API `sha256:fadabb52cd61c078599ceda2544cea6f34dd85b0dbc0b6c5d276c5d3a96ab7dd`，Worker `sha256:3c9e4bbf4760edd173263efb8a8ad2cbee99af9a287402c4d885f5186eaadaaf`，schema 0092 | 后继 friend-video 任务镜像；本轮实施基线 `1a246939` | API/Worker 容器 | `manual_payouts.py`、`support_payout.py`、TronGrid reader、充值 workflow 与本工作树逐字节一致；镜像必须以当前 `fadabb52` 为基底 | 本轮只读，非候选发布 |
| 后台提现/充值静态 | 生产/公开静态原始 SHA 与本地不同，经 CRLF→LF 归一逐字节一致 | `1a246939` 内容 | HTTPS 静态 | 生产 payout `a61ab9f8…`、recharge `15685b3b…`；仅行尾差异，发布需按最终原始 SHA 核对 | 本轮未发布 |

本次正式基线详见[实施证据](../../verification/2026-09-30-support-finance-order-recovery.md)：后端专项 143/143、前端专项 46/46、隔离 PostgreSQL 4/4；这些是修复前回归基线，不代表新行为通过。红绿输出、最终输入 SHA、迁移及发布证据实施中补齐。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 代码/现网只读调查及用户决策 | 2026-09-29 本轮，准确开始时间未记录 | 约 23:05 +08:00 | 主动调查和 SSH/测试工具；并行代理，准确耗时未知 | 取消、链上、认领三条独立核查 | 生产后端一致、静态故障存在；用户明确四项行为与发布范围 | 书面规格 |
| 书面规格起草与自查 | 约 23:05 +08:00 | 约 23:25 +08:00 | 主代理文档；三项只读评审并行；首轮审查意见逐项修正 | 主代理/三代理 | [规格](../../superpowers/specs/2026-09-29-support-finance-order-recovery-design.md)在 `ffc9132b` 提交，用户批准；领域/链上/权限 P1 已逐项修正 | ADR/计划 |
| 受保护 ADR 与逐项计划 | 约 23:25 +08:00 | 约 00:10 +08:00（次日） | 主代理起草；三项只读 ADR/计划复核，逐项修订 P1；未改产品代码 | 主代理/三代理 | ADR 补齐已有付款凭证；14 项计划补齐候选入单、owner 证明、PG 触发器与按 actor 能力投影，待用户批准 | 请求批准 |
| 实施授权与基线 | 2026-09-30 00:22:03 +08:00 | 进行中 | 主代理本地 Python/Node/隔离 PG；生产代理经 jumper 只读核对；Tron reader 和迁移实施并行 | 主代理/`prod_baseline`/`tron_reader_impl`/`migration_impl` | 用户要求代码及生产；本地唯一 0092、生产唯一 0092、后端 143/143、前端 46/46、隔离 PG 4/4；现网 API 已有后继镜像须作为候选基底 | 完成实现、两阶段审查和发布门禁 |

总墙钟与并行区间：本轮准确起点未记录，不估算总分钟数；后续从明确时钟采样开始记录。已记录各专项测试自身耗时；分段实施精确起止缺失，不估算总墙钟。尚无本轮生产部署时长。

## 交接与回退

- 已确认根因/已排除假设：`adjust-rate` 独立先提交 `begin-payment`，使未付款单也成为 `CLAIMED`；失败后该状态仍残留。取消仅允许 `REQUESTED`，Android 直接显示服务端英文代码。链上 reconcile 无候选时不查询 TronGrid，地址仅在 begin 响应，前端外层入口不看他人认领。
- 待办及验收失败项：SFO-1 至 SFO-5 已有实现及红绿/隔离 PG 证据；最终前端/提现复审、SFO-6 受控发布与真实会话验收待完成。现有受影响订单 ID 未提供，不能推断其链上未付款。
- 已发布与仅候选的区别：此前钱包工作台和 Android 2193 已发布；本轮实施已获授权，但尚无 API/后台候选或新 APK，生产尚无本轮写入。
- 生产备份位置、恢复操作、漂移检查、可重试阶段：本轮尚无生产写入或备份。按批准计划切换前再次冻结实时镜像、静态、schema、Compose 与私有备份；不对现有已开始订单直接回滚资金。
- 运行中 CI/命令/自己创建的隧道（无凭据）：本地专用 `starchat-support-recovery-pg` PostgreSQL 容器运行中；无 CI、构建或本任务创建的 SSH 隧道。独立子代理负责链上 reader、迁移和现网只读核查，主代理负责整合。
- 下次恢复先检查的事实：用户实施授权已记录；重新核对生产 API/静态和 0092 后继变更，再按计划继续红灯/绿灯及受控发布。D 盘脏工作区不得直接用于生产发布。

## 2026-09-30 实施恢复记录

- 已实施提交：`41200e1e` 0093 扩展迁移；`45acdc2e` bounded TronGrid discovery；`7b7b32d5`/`a575c53a` 精确释放及冲正；`8a76ad29` 暂存汇率与原子开始；`17fcb2bd`/`67ac473a` 拒绝与租约终检；`f72ef2de` 单独审计完整地址；`a3d18d30` 充值接管；`5988f219` 当次凭据绑定、安全重放、只读收据能力核对；`42c888ae` 提现/充值前端修复。链上选择及提现接管仍由 payout_finish 完成，尚未冻结候选。
- 最新 proof/identity/充值/公开 receipt 隔离 PG 聚合：47 passed，45.99s，无跳过；此前 TOTP credential replacement RED→GREEN，接管重放 RED→GREEN。前端专项及 source contract 75 passed；全前端 416 passed/5 untouched UI drift failures。
- 完整 `verify.ps1` 实际 exit 1：Repository/Deployment/Template PASS；render-only 缺 `.env` 停止。未声称全仓通过；Flutter 不在 PATH。
- 2026-09-30 本轮恢复时生产只读镜像核对：API `fadabb52…`/Worker `3c9e4bbf…`，running，restart 0，与冻结一致；本任务仍未切换生产。
- 下一步：完成 Task7–9、前端独立规格/安全复核，导出 OpenAPI；Task14 新发布工件在准备，基于现网镜像最小覆盖，冻结源码后执行迁移克隆、候选/回退双角色门禁与受控切换。真实后台会话/安全资金测试单未提供，产品会话验收保留待办；历史已开始单不自动退款。

- `c03737b0` Tasks7–9 完成：发现、明确 log_index/claim_version 选择、最终跨订单归属、独立 evidence 接管；269 聚合通过，后续 discovery/takeover 20 通过、最终 discovery 16 通过；PG 12 通过58.89s及变更增量4通过17.55s。独立最终领域/安全审查运行中。
- `5356e028` OpenAPI 导出及新 route/version/proof 合同红绿：5 passed；迁移16 passed/26.77s，唯一 head0093；OpenAPI --check PASS，AST251 PASS。Task10 scoped spec/domain then security review PASS，无P0–P2。
- Task11/12 独立复审发现5项P1（实际响应token保留、候选 log_index/version、接管claim_version、发现失权地址清理、prepare等待期间失效仍execute），实施代理正在统一修复，未上线。API/Worker 全目录回归运行于session26639，输出 backend-all.log；勿重复启动相同门禁。

## 发布预检裁定：Worker 共享模块

2026-09-30 13:44 +08:00 前后（准确分钟以后续工具时钟为准），release implementer 检查发现现网 Worker 独立安装业务 API app package，`ManualWalletMaintenanceTask` 不依赖新资金开关而持续对 CLAIMED/UNKNOWN 调用旧 `ManualPayoutService.reconcile`。仅更新 API 会让自动核对绕过本轮新的跨订单归属校验。

Ruling: 将本轮已获批准的共享资金模块同步覆盖到 Worker 实际 site-packages 导入来源及 /opt/business-api 镜像副本，Worker任务代码不改；候选和兼容回退都保留同一安全核对，双角色门禁和隔离克隆验证后切换 API/Worker。依据是用户已授权产品及生产修复，Task14 “代码不改则保持Worker”条件不满足共享依赖实现更新；保留旧Worker无法实现规格。代价：需要重建并受控重启Worker，扩大到两服务的发布清单，必须证明其余任务/配置与容器不变。独立领域审查正在验证精确模块及恢复边界，未做生产写入。

Ruling: 受控切换使用 fenced API bridge，由已验证的兼容镜像启动扩展0093并暂时拒绝提现/充值HTTP写入；隔离迁移及候选/回退双角色门禁先通过，随后guard先切安全Worker再候选API/静态。依据是防止旧adjust-rate在迁移/切换窗口继续自动开始出款；保留原数据。代价：短暂写入口不可用及两次API受控重启，需要逐阶段绑定实际镜像/Compose/schema并支持从bridge恢复。尚为发布工具实现方案，未执行生产切换。

## 完整基线源码漂移核对

2026-09-30 05:51:13 UTC snapshot 冻结API fadabb52、Worker3c9e4、schema0092、实际Compose及全部拟覆盖文件。主代理逐条比对Git1a246939原字节：API recharge.py/service.py有已发布7bffa68c绑定门槛、先完成重放后FX、参考率校验增量；已从不可变镜像安全读取三份源码并SHA绑定到support-source-drift。该变化不能被本轮覆盖，payout_finish按现网submit语义与本轮接管代码整合，冻结候选暂停至专项及复审完成。WalletRechargeBindingGate的已发布来源dd70c1a9，现网镜像已含该模块，本地会恢复同源代码和测试fixture。Workerledger差异仅缺管理员read-only balances_for；五文件共享安全闭包同步API当前类时新增该无写入方法，不损失Worker规则，源码SHA仍按本轮portableprobe绑定。暂无生产切换。

## 2026-09-30 06:45 UTC 最新恢复与发布基线

- 生产另一授权钱包任务于13:59:33 +08发布API `sha256:902eaefcb237924caf9b60145f728f9e2b4ec67fc2b659bd98ad7ea82edd101f` / Worker `sha256:90d7fb7472c82b78b9a9a56ef114620dd0aa0bd4a989e3011e3aa4ed24537282` / schema `0093_unbroadcast_payout_void`。06:37:48 UTC新只读snapshot已重新确认；上文fadabb52/0092仅为历史，不能用于新发布。
- `479d4d57`保留不可变当前API镜像的非重叠模块及0093 VOID，恢复已发布监控行为；本次扩展迁移重编号0094→0093，22迁移/历史链专项通过23.02s。OpenAPI重新导出/check通过，包含已发布void接口和本次恢复接口。Worker additive AuditWriter保留其实际内部发布helper，所有API财务audit方法AST与当前API一致。
- `4f17fb82`/`ec1e128a`保留VOIDED精确原始资产/管理员actor；`c4c96fb9`显式review仅清payment_verified_at、保留receipt/binding，严格Worker恢复事件合同。独立finance规格/领域及质量安全审查无P0–P2，121专项通过15.65s；提现合并最终独立复审待办。
- 全API/Worker已完成：3276 passed / 73 skipped / 6 failed / 1既有httpx弃用warning，2496.21s。6失败分别为两项旧head断言、发现截止旧采集输入、review未清付款验证、Worker合同缺失、旧UNKNOWNfixture。最终聚焦复测已分别关闭；不将最初全量exit1改称通过，不重复41分钟同输入无关门禁。完整verify仍缺本地.env；未导入生产secret。
- 发布工具补齐Worker逐阶段ID、兼容回退允许受控重建且禁止未授权替换、admin void写入口fence。55行为专项通过，独立工具审查待完成。portable probe `b6108a7f` SHA `3c86002497d334b43c412e7736f99f6392780a7d3d5f3eb4022adf8b7ba4be33`绑定6业务模块和2实际Worker任务，要求0094。
- 下一执行步骤：完成独立工具/提现复审，冻结当前源码和实时snapshot；服务器私有备份、隔离恢复0093→0094、实际Worker旧红新绿、候选及兼容回退双角色门禁；bridge→Worker→API/4静态受控发布。尚无本次生产服务/数据库/静态变更，真实角色会话验收仍待提供账号。

- 新0094隔离PGv2专项：recharge并发/直接settlement/receipt 31 passed，9.24s，无跳过；未使用生产资金操作。

## 06:51 UTC 发布执行阶段

- 最终独立release工具c204审查PASS；VOID合并12tests独立PASS；恢复基线22+5contracts独立PASS。06:51:05 UTCsnapshot镜像/schema/config/file与既有baseline一致。冻结sourcec204，archiveSHA `9f4ba401318c434d21a00e5304b02aeaa6cb2f4c0275da0c69d8f6e13e0383b4`，manifestSHA `42ad9a8e293a452165343aefa4ea07dc498c47dfc720b35e06bb92a8d6bdf21d`。服务器上传哈希校验/preflightPASS。
- preparePASS：备份SHA `d76ea3434f99dd33b48ff83dcde5c0503d8f6687fa4d9557ba7d1ba068b52a23`，私有目录 `/opt/starchat/releases/support-finance-order-recovery-20260930-v1/private`，备份未下载。冻结目标2服务，其他28容器。
- build在构建前拒绝：工具假定startup含alembic，而actualCmd仅uvicorn factory port8082 workers2，Entrypoint null。尚无候选image/context/服务切换/schema写入。修订工具红绿及独立审查进行中；不得规避检查直接发布。
- Ruling：保持actualCmd与Compose，先guard激活fencedAPI、核实health及HTTP写503，再单次dockerexec迁移0094；避免未fence迁移窗口和两个uvicornworker并发迁移。迁移失败保持fence并保留私有attempt证据，不盲目恢复unfenced旧API。产品payload仍c204冻结，工具更新独立SHA记录。该裁定实现中、未执行。

## 后续服务器门禁（07:25 UTC 前后）

- 02e0f382 startup修订60tests/独立审查PASS，两文件SHA门禁原子替换；产品sourcec204不变。第二build构建API27028fd5/Worker7a0046de/兼容API913e6b79，库存PASS；真实derivedcompose bothservices合并覆回旧API，被strict merged check拒绝。
- 072dd62f修订角色派生配置仅含所属服务，其他顶层/服务配置严格保留；65tests/独立审查PASS。两文件SHA门禁patch3375483b…；resume-build以三个固定ID完整重验Config、库存、sourceintent，归档旧派生文件并保留contexts/logs，候选及兼容回退双角色guard与兼容归档PASS，attempt `resume-build-c1915b96b9894cc99daf0e921af50f9d`。
- restorePASS：ownedclone `admin-entry-restore-39148463f671`，network none/no publishedports，从同一私有备份恢复真实0093。probe-clone已在隔离库扩展0094，但模拟UNKNOWN订单缺claimed_by/claimed_at，并共用quote，违反真实constraints。未形成clonecompatibilityproof，production切换继续阻止。
- 下一步：TDD补完整真实PG合法fixture、独立审查只改probeSHA的版本化manifest绑定，以及只清理exactownedclone/anonymousvolume后重建同备份克隆。不得用已0094库伪造beforefingerprint，不修改生产订单。本次尚无API/Worker/schema/静态生产切换。

## 再次真实生产漂移：保留已发布客服邮件修复

- c315c4f5探针fixture真实PG RED→GREEN1/5.31s含actualASGI ready200/写503/匿名401403；623382f3恢复11负例/字段结构tests及独立领域/安全PASS，三个工具文件SHA门禁替换。amend-probe在check_prepared安全停止，尚未改manifest/baseline或清理克隆。
- 原因：另一授权staff-mail任务07:43:49 UTC切换Worker至 `sha256:00c0e10972c97f18d5aae435032da642ad2a7752265dd66cfe4712ec3268c5b7`，API902/schema0093不变。用户已确认正式开通邮件收件。root全Pythoninventory证明只改staff_activation.py两副本69cf→4b5ebc44，与API-v2同源；镜像Config完全相同，容器Env值完全同但排序变化。当前WorkerCompose guarded-xocl5j_i。该邮件修复不得被旧7a候选覆盖。
- Ruling：v1保留所有备份/镜像/失败证据，因生产漂移作废；严格验证exactownedclone9bffed…及匿名卷b4b77e…后只清理该隔离资源（独立审查新cleanup-only路径），不修改原v1绑定。v2从新Worker00c+API902重新冻结snapshot/私有备份/候选，产品sourcec204及14Workeroverlay不变、继承base中的邮件修复；重跑实际镜像/克隆发布门禁，不重复不变产品源码门禁。尚无本次生产切换。
- root临时jumperloopbackSOCKS端口18948，execsession87150，本任务创建，公开验证后必须关闭；不改变全局代理。

## V2 准备与源 Compose 门禁（2026-09-30）

- 46e38c8d 独立审查PASS；只替换clone_recovery.py，SHA b740ad0c701887e00818888a73ea02010ad5e20d25e39d5ce4ebce8116bd308a。cleanup-only成功删除记录中的隔离clone9bffed…及匿名卷b4b77e…，保留v1私有失败日志/原manifest与baseline；无restore、无生产改动。
- V2 source仍c204d415；manifestSHA c32fe3b6b8de5c8ee1937e00167418db43da3f8a835e61cdd4554f3fc7847d12，archiveSHA 9b8861c879bcc7275f207f41816d06d79fa55ae4f445d4b69f2d1fbf248bafd0；上传严格校验PASS。
- V2 preflight在prepare之前拒绝：API源Compose含旧Workerpeer，而当前Worker已单独发布00c。没有创建私有备份、构建、迁移或切换。本轮前述072dd仅修派生candidate/rollback，源baseline读取仍错误地要求两个历史源中的peer相同。
- Ruling：每个实际容器标签绑定的源Compose只以所属service为权威，精确SHA与所属live镜像/Env继续核对；完整合并baseline由两个所属角色派生并严格核对，不把旧peer当现状。必须TDD/独立领域及安全审查，通过后只SHA门禁替换工具；产品manifest/payload不变。成本是多一轮发布工具修订，不能牺牲实际配置检查绕过门禁。

## V2 作废与 V3 保留新汇率参考访问增量（08:35 UTC 起）

- 70bf566d工具修订9tests/独立领域与安全PASS，单server_release.py SHA门禁替换至bf7b39414d5ceddac69e2c54f4d4002291a4e9154c0bdddc506e78e6e428496e；manifest/payload未改。重跑preflight因api image drift停止，prepare未执行。
- 08:35:24 UTC现场snapshot：API d791c7fc2facaf5d44ee9c082903aaf62fd1eec37c1352ef87b1abc42e085f95，Worker00c/schema0093不变。另一授权任务finance-reference-read-access于08:20:42 UTC发布汇率参考只读权限与UI并已获真实客服验收。完整API库存902→d791仅recharge.py变动，imageConfig完全相同；目标静态仅admin-recharge-panel.js变动。实际发布artifactSHA与线上SHA严格相同。
- Ruling：保留V2原冻结包与失败证据，不重绑定；精确合并已发布reserve_valuation路由与refreshFxUI，保持本轮恢复逻辑，其余新生产文件依托d791/00c基线。V3 release_prep只改releaseID和BASE_API，Worker/角色门禁不变，重新冻结实际snapshot与新source后跑私有备份和真实镜像门禁。成本为增量红绿/独立复审和新包，不重复不变41分钟全量。
- frontend04fbc230 RED4failed45pass→GREEN49pass/325.87ms；导入接口兼容，实际strictTLS静态Cache-Control:no-store，四文件发布足够刷新读取新模块。
- Backend公布路由增量RED2failed13pass→GREEN15pass/49.67s，仅reserve_valuation AST变动，其他路由AST保持；独立审查进行中。08:40:55 UTC OpenAPI重新导出/checkPASS，生成契约无diff。
- 本任务截至此处仍无生产API/Worker/schema/静态切换，V2无private备份/候选；V1仅清本任务隔离clone，备份和日志留服务器。
