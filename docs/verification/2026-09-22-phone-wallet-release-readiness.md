> **后续状态：** 本文为发布前历史审计，阻断已通过隔离整合与迁移演练解决并获用户发布授权。当前线上见[2026-09-23发布报告](2026-09-23-phone-wallet-live-restore.md)。

# 手机认证 / 钱包后端发布就绪审计

证据采样时间：2026-09-22 23:05 +08；报告校验时间：2026-09-22T23:08:00+08:00；只读源码/历史发布证据审计。未连接生产、未读取秘密、未发送短信、未修改业务代码/数据库、未创建或发布候选镜像。本报告不等于可部署结论。

**结论：当前主工作区不能直接部署。** 主代理已确认在线镜像缺少 phone/fx/recharge/group-transfer 路由；本审计进一步确认本地后端缺失线上已经发布的刷新恢复协议与迁移。修复客户端提示不能补齐服务端能力，客户端 Debug 安装也不代表配套后端已上线。

## 证据身份与范围

- 发布工作树：`.worktrees/chat-reliability-diagnostics`，分支 `codex/android-040-release-20260922`，HEAD `5acfb3469fbfaf3e8459cae85c871a037641cf64`；发布候选 `28bdfc48`，后端输入来源 `28287811`。
- [发布报告](../../.worktrees/chat-reliability-diagnostics/docs/verification/2026-09-22-android-040-release.md)记录镜像 `starchat-business-api:refresh-040-20260922`，digest `sha256:b7d38f99879d6dff1375e527e20552e0f04c1d328c4e893330d91ba53b9ad6cc`，真实迁移 head `0080_refresh_recovery`。本项为发布历史证据；当前运行状态由主代理本轮只读核验负责。
- 主工作区 HEAD `0125d50ab4fcc89a41aa5d8fcd528a83dbe22622`，包含未提交并行修改，`0082_deposit_intent_cancel.py` 在审计时为未跟踪的新文件，仍需所属任务冻结。
- [逐文件差异与原始字节 SHA256](artifacts/2026-09-22/phone-wallet-readiness/source-differences.json)：比较源码时消除 CRLF/LF 差异，实际差异为 API `app/` 50 文件、迁移 12 文件、worker `app/` 5 文件。它是**待审差异清单，不是部署允许清单**；依赖锁、OpenAPI、部署装配与测试文件尚需单独冻结。
- 方法：只读 `git worktree list`、发布清单/报告、`git diff 28bdfc48`，Python AST 提取 revision/down_revision/DDL；没有运行生产迁移或声称数据库演练通过。

## 迁移分叉与具体影响

发布链：`0071_direct_room_generations → 0080_refresh_recovery`。

本地链：`0071_direct_room_generations → 0072_fx_rates → … → 0081_recharge_binding_history → 0082_deposit_intent_cancel`。本地完全缺少 `0080_refresh_recovery.py`；`0080_group_transfer_intents` 与它数字前缀相同，但 revision ID 不同，不能替换、重命名或 stamp 成另一条链。

下表为迁移源码中的逻辑表名；生产物理表名/列类型必须在恢复演练和实际 schema 检查中核对。

| Revision | 本地相对发布链的结构/数据变化 |
| --- | --- |
| 已发布 `0080_refresh_recovery` | `refresh_tokens.operation_hash`、`result_key_version` 两可空字段；保留既有恢复元数据，downgrade 不删除 |
| `0072_fx_rates` | 新建 `fx_rates` |
| `0073_pricing_v2_reserve` | 储备增加点钻面额、待付 USDT、估值汇率、参考 USDT 与估值时间；不是单纯手机功能 |
| `0074_red_packet_commission` | 红包免手续费、群人数、佣金受益人/金额/状态、规则版本字段 |
| `0075_business_groups` | 新建业务群注册表 |
| `0076_payout_settlement` | 人工提现增加最终汇率/应付、调整摘要与历史 |
| `0077_recharge_requests` | 新建充值申请与客服目录表 |
| `0078_phone_accounts` | 用户手机号/归一化/验证时间/隐私字段及唯一索引；邮箱改可空；PG accountstatus 增 `PENDING_PHONE`；新建 OTP 挑战表 |
| `0079_recharge_credit_bindings` | 新建充值申请与财务指令持久绑定及唯一约束 |
| `0080_group_transfer_intents` | 新建群主转让阶段、领取锁、错误码和幂等操作表 |
| `0081_recharge_binding_history` | 绑定状态判别列改可空、增加已批准结算快照；将历史 `state_active='0'` 改为 NULL；禁止破坏性 downgrade |
| `0082_deposit_intent_cancel`（待冻结） | 充值意向状态约束与不可变触发器支持 CANCELLED；新建不可变取消命令回执表及用户/幂等键唯一约束；禁止破坏性 downgrade |

安全集成方案：保留两条原 revision 历史，在独立候选中新增一个**合并 revision**，`down_revision` 同时指向 `0080_refresh_recovery` 和最终冻结的业务分支 head（当前为 `0082_deposit_intent_cancel`），无额外 DDL；最终编号须核对其他任务占用后决定。这样从生产刷新 head 升级会补执行业务分支，再收敛到单 head。不能通过覆盖 alembic_version、删除刷新迁移或把 0072 的既有 parent 改写来伪造兼容。若仅发布手机号而不接受整条业务链，必须另设计隔离迁移/发布切片，不能跳过前置 revision。

## 必须保留的已上线行为

[原七文件发布清单](../../.worktrees/chat-reliability-diagnostics/docs/verification/artifacts/2026-09-22/android-040-release/manifest.json)覆盖 `api/identity.py`、`api/client_diagnostics.py`、`modules/identity/{matrix_login,matrix_sessions,models,tokens}.py` 与刷新迁移。

本地 `TokenService.rotate` 相比发布版本已经没有 `operation_id` 参数、确定性恢复结果、相同操作重试恢复及 `REFRESH_RESULT_SUPERSEDED` 处理；本地 identity API/models 也缺少相应协议字段。因此不能把本地 identity 文件整文件覆盖到在线镜像。必须三方合并手机号新增与发布版刷新恢复，保留旧/新刷新请求兼容、真实重放撤销、结果已推进不撤销族、设备/账号归属及状态检查、Matrix 会话完成逻辑和脱敏诊断。仅保留数据库两列不能保护协议行为。

## 尚未形成候选的阻断项与下一步

这是跨认证、账本/红包、钱包、worker 和群转让的集成任务，不能在本次只读审计中把 67 个差异文件直接组成发布包。当前没有已合并的候选分支、没有集成后的单 head、没有候选镜像 digest，也没有基于生产刷新 head 的新迁移恢复证据。

下一步可执行准备命令（**尚未执行**，先核对分支/路径不存在）：

```powershell
$OutputEncoding = [Console]::InputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
git branch --list codex/phone-wallet-live-compat
Test-Path -LiteralPath '.worktrees/phone-wallet-live-compat'
git worktree add -b codex/phone-wallet-live-compat .worktrees/phone-wallet-live-compat 28bdfc48
```

随后在该候选中逐项执行：

1. 冻结取消任务 0082 与所需模块、测试、依赖锁、OpenAPI 的 SHA 清单；基于上方差异清单逐文件判断“保留发布版 / 三方合并 / 新增 / 排除”，不得复制整个脏主目录。短信 SDK、API/worker 的装配及金融规则变更纳入明确评审范围。
2. 首先合并认证冲突并加入迁移 merge；离线检查唯一 head 与两边升级路径。安装包已经支持的刷新协议必须先由定向测试证明不退化。
3. 将服务器备份保留在受控服务器目录，恢复到隔离 PostgreSQL，验证从真实 `0080_refresh_recovery` 升级、历史指纹/余额/会话不变、取消不可变历史及并发、手机号 OTP 用途/单次消费、刷新并发/重放/结果恢复；不得把生产秘密复制进本地测试。
4. 先规格/领域审查，再质量安全审查；跑候选受影响测试、OpenAPI/迁移/依赖锁检查与适用完整 verify。原分支绿测不能替代新候选的合并门禁。
5. 准备当前运行镜像增量 manifest、固定依赖镜像、API/worker 配套部署顺序和备份/回退。保留扩展 schema，不进行破坏性 downgrade；回退仍须支持 0.4.0 刷新协议。

## 生产授权与 App/后端对齐门槛

本轮修复与 Debug 验证不自动授权上线整个未发布业务批次。应当在上述**具体候选**完成、可审查后，由主代理请求明确批准：实际部署的 API/worker/后台范围、包含的定价/红包/提现变化和全部迁移、手机功能与 SMS/FX 配置启用范围、维护窗口及回退。群转让开关保持关闭，除非另有明确启用批准；手机号功能开关及供应商配置必须以生产校验为准，本地短信验收不等于生产已配置。只检查配置存在性，报告不写入值。

后端先部署并验证，后发布依赖它的正式 App。验收至少包括认证路由受保护返回而非 404/405、真实开关与 schema 对齐、配套客服目录/汇率/充值取消的合同、旧邮箱登录和 0.4.0 新旧刷新协议回归、非本任务服务/移动平台发布配置不漂移。无真实 SMS 发送授权时仅做不发码的路由/配置/隔离替身验证，不能为探测功能而给用户发短信。Debug 可用于 UI 复验，但必须明确标识其当前依赖的后端尚未上线。

