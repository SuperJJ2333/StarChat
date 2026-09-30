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
