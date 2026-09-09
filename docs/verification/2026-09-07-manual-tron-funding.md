# 单源与人工钱包资金集成进度

依据 [ADR-0013](../adr/0013-trongrid-single-source-manual-payout.md) 及 [实施计划](../superpowers/plans/2026-09-07-manual-tron-funding.md)。用户已确认：官方地址由 imToken 管理，TronGrid 单源，由官方钱包拥有者管理员本人确认和人工付款，无第二审批人员，USDT 服务费零。

## 2026-09-07 续作：告警升级与客户端接口

- 用户已确认人工付款拥有者账号为 `admin`；本轮尚未写入生产配置，也未调整其他管理员的权限。
- 隔离 PG16 完整流水管线验收通过：登记待处理款、发布储备、唯一入账及再次运行不重复记账。备份恢复到独立库后，以新应用进程重放仍无财务副作用。证据：`runtime/monitor-pipeline-v2-pg.txt`、`runtime/reserve-restore-guards-pg.txt`、`runtime/monitor-restore-restart-pg.txt`。全部使用合成链上证据，不代表真实资金验收。
- 首次全仓检查为 **1110 通过、31 跳过、1 失败**，失败是既有邀请码倒计时在轮换前不足一秒显示 0。固定时钟边界测试先 RED，再以向上取整修复显示，邀请码实际轮换/失效规则不变；相关 11 项通过。证据：`runtime/referral-boundary-red.txt`、`runtime/referral-boundary-green.txt`。完整重跑日志 `runtime/reserve-integration-verify-rerun.txt`，结果另行确认。
- 独立审阅发现人工监控替换旧监控后遗漏 P0 定时升级。现于扫描锁内、来源读取和储备事务前调用公共事故升级接口。源故障仍升级；升级失败禁止发布储备；同时间槽不重复升级。先 2 RED 后 70 通过、1 既有 PG 跳过；规格独立复核连同邀请码测试 81 通过、1 跳过。证据：`runtime/monitor-escalation-red.txt`、`runtime/monitor-escalation-green.txt`。
- 后台 API 封装新增人工提现列表/详情、领取、候选交易哈希提交/更正及共享 MFA 接口，命令必须由调用者提供稳定幂等键，读取和命令禁止缓存，不将候选哈希标为已结算。5 项新增测试先 RED，相关 14 项 GREEN；证据：`runtime/admin-manual-api-red.txt`、`runtime/admin-manual-api-green.txt`。此处只交付接口封装，实际页面尚未接线。
- Flutter 新增 `manual_wallet_api.dart`：绑定、充值意图、提现报价/订单及 MFA 强类型契约。9 项测试、定向 Dart analyze 通过；独立规格与安全审阅均 PASS。401 刷新保留正文与操作键，金额不经浮点，必填快照/未知状态失败关闭，敏感数据不持久化。证据：`runtime/flutter-manual-api-green.txt`、`runtime/flutter-manual-api-analyze.txt`。调用页面仍负责持久化业务操作键；后端 MFA 不承诺幂等重放，不可据请求头推断可安全重复注册。
- 后台新增封装的规格/安全审阅 PASS；完整前端 Node 测试 38 项通过，证据 `runtime/admin-manual-frontend-all.txt`。告警升级安全复审 70 项通过、1 既有 PG 跳过。邀请码短期稳定性测试另注入固定时钟，避免两次请求跨真实轮换边界造成随机失败，11 项通过，证据 `runtime/referral-clock-green.txt`。
- `runtime/reserve-integration-verify-rerun.txt` 全仓重跑返回 0 / Verification: PASS：API/Worker 1112 通过、31 跳过，移动边界65、基础设施50、推送28、机器人9；UI contract、0050 迁移、OpenAPI、Compose 均通过。该轮已开始收集测试后加入的告警升级两项及固定时钟调整另有上述聚焦验证，不能把它们计入该轮 1112。后续投递状态接线不由此轮验收覆盖。
- 新发现的未完成项：后台监控状态仍固定返回外部投递未配置，尚未读取实际 Worker 投递配置；人工模式事故条件清除与受控结案尚未接通。不得据此声称事故恢复验收完成，不自动清除事故或解除暂停。
- 上述投递配置状态已继续修复：0051 新增心跳配置布尔列，Worker 实际创建非禁用钱包告警 handler 后才标记 true，后台读取持久值，过期/错误独立显示；不保存邮箱或密钥。规格独立 90 项、安全 88+1 项通过，root 83 项聚焦通过。迁移先 RED 后相关 10 项通过，隔离 PG16 扩展、默认值/旧 writer/非空约束及备份恢复通过：`runtime/monitor-delivery-migration-pg.txt`、`runtime/monitor-delivery-guards-pg.txt`、`runtime/monitor-delivery-restore-pg.txt`。完整重跑日志 `runtime/delivery-final-verify.txt`，不能复用前一轮结果。人工事故恢复流程仍未接通。
- 0051 备份恢复库以全新应用容器进程分别验证 true/false 配置，共享状态读取正确，已核验截面、CREDITED 收据、账本数量及储备版本/时间/负债保持不变：`runtime/monitor-delivery-restart-true-pg.txt`、`runtime/monitor-delivery-restart-false-pg.txt`。这是隔离配置注入验证，并未实际投递邮件。
- 用户再次强调官方充值地址固定。补充 8 组 API 拒绝测试：普通用户/付款管理员分别向充值意图/提现报价请求注入官方地址或配置版本，均返回 422。相关13项通过，证据 `runtime/official-wallet-override-tests.txt`；此项补测不改变既有服务端地址配置。私人钱包签名资料与设备限制另见 [兼容性核对](2026-09-07-wallet-signature-compatibility.md)，不把第三方钱包安装列为 MI 6 测试平台 App 的前提。
- 0051 接线后全仓检查 `runtime/delivery-final-verify.txt` 返回 0 / Verification: PASS：API/Worker1119通过、31跳过，移动边界65、基础设施50、推送28、机器人9；UI contract、0051迁移、OpenAPI、Compose均通过。上条官方地址补测在该轮测试收集之后添加，单独13项通过，不计入1119。已知 Starlette/Pydantic 弃用提示仍来自现有依赖，未屏蔽；环境依赖跳过项不表示在本地被执行。此结果不替代生产启用及真实资金验收。

尚未构建新正式 APK、发布更新弹窗、部署本轮代码或启用真实资金。

## 基础部分历史证据

- 充值意图基础：27 项新测试加 41 项绑定回归，根任务独立重跑 68 通过；规格与质量/安全独立审阅均 PASS，仅覆盖基础范围。
- 改绑原子关闭旧意图：先出现预期失败（旧意图仍 OPEN），实现后相关测试 70 通过；激活审计失败同时回滚绑定与关闭，不改写来源快照。
- 迁移 `0043_funding_intents`：新增表、模型注册、OPEN 唯一约束、金额约束及 PostgreSQL 不可变触发器。含迁移的相关测试 71 通过。
- 在独立 PostgreSQL 16 容器执行完整离线迁移 SQL，迁移成功；实际数据库拒绝修改金额/规则、删除、重复 OPEN 和重新打开关闭的意图。合法关闭成功。
- 对上述隔离数据库执行 `pg_dump`，恢复到新的隔离数据库，再运行相同检查通过。此为新空业务库的结构/约束恢复演练，不代表生产资金恢复验收。
- 单源适配器实现者报告 82 项适配器与既有 reader 测试通过；逐日志保持原始索引，缺失或错误证据只表示不可核验，不推断付款失败。
- 根任务于 2026-09-07 07:46 UTC 使用新适配器对用户此前确认的两笔历史交易进行真实只读核验，均匹配固化收据及区块成员，各一条 USDT 日志，金额分别 2 和 12。脱敏证据 `finality/live-read.json` 未保存完整地址或交易哈希；此检查没有资金入账。
- 基础阶段全仓 `scripts/verify.ps1` 返回 0；改绑、迁移和单源适配器合入后的全仓检查另行记录，不能复用基础阶段结果声称新改动通过。

证据均位于 [本次目录](artifacts/2026-09-07/manual-tron-funding/)。迁移/改绑集成和单源适配器的规格与质量/安全审阅均 PASS（审阅者分别运行 91 项相关测试通过）。

## 后续集成证据

- 链上普通单密钥权限核验、绑定策略适配、真实 TOTP 验证接口及限流桥接、`0044_binding_policy` 已通过领域和安全审阅。缺少 active 权限字段时失败关闭，不能默认当作无委托。历史绑定保留 `LEGACY_UNSPECIFIED`。
- `0045_deposit_receipts` 新增逐日志事件和异常记录，并允许意图 `FULFILLED`。充值匹配、审核义务、复式账本、意图完成及审计/Outbox 在同一事务内处理；矛盾或消失的已知日志永久隔离。
- 已修复默认 Decimal 28 位上下文可能导致的极大金额静默舍入；精确汇总与整个金融保存点使用足够精度。溢出或账本精度失败保留 REVIEW 并使储备失效，不丢失收据。最终领域及安全复审 PASS，范围仅为充值核心。
- 安全复审发现重复扫描会修改储备版本但不重复入账；现已修复为新收据才同步、相同负债和重复失效均无操作。先有 8 项预期失败，后 46 项充值测试通过，钱包/账本回归 296 通过、4 既有跳过；独立规格与安全复审均再次运行 46 项通过。隔离 PG16 使用新应用进程重放隔离事件，储备版本/时间/负债均不变，证据 `receipts/replay/pg-restart-noop.txt`。
- 隔离 PG16 实际执行 `0044` 与 `0045` 成功，实际触发器检查 PASS。新应用代码在独立只读应用容器中连接隔离 PG16：8 个并发意图请求只创建一单，8 个并发相同充值请求只创建一笔账本，分录合计为零、负债精确为 10；随后目标地址冲突触发隔离。重建应用容器后再次重放仍隔离且没有重复入账。所有账户、金额场景与链上证据均为合成，未接生产数据库。
- 完整检查日志 `receipts/full-verify.txt` 以 `Verification: PASS` 结束：业务 API/Worker 709 通过、31 按现有条件跳过；移动边界 65 通过，迁移和 OpenAPI 检查通过。既有 Pydantic/Starlette 弃用警告不是本次新增。此前旧迁移 head 断言失败已随新迁移更新，并由本次完整检查覆盖。

## 未完成的资金闭环

### 储备与重试接线续作

公共储备发布接口经过 RED/GREEN、领域与安全审阅（48 项通过）。完整来源截面摘要、余额整数与六位金额一致性、证据到期、来源进度回退、在途计数、乐观版本、数据库身份映射缓存、同事务点钻负债、幂等重放及审计/Outbox 回滚均有断言。0050 已在独立 PG16 执行，实际 UPDATE/DELETE 和非法版本推进被拒绝，证据 `runtime/reserve-migration-pg.txt`、`reserve-guards-pg.txt`。

独立克隆的合成数据库验证 Numeric(30,6) 最大金额精确保存、8 路相同储备发布只保存一份评估、失效后过期重放及新应用容器重放均不刷新储备，证据 `runtime/reserve-gateway-pg.txt` 与 `reserve-gateway-restart-pg.txt`。该网关测试的输入是专用合成夹具，不代表生产余额或负债。

专用人工监控已替换 Worker 的旧托管监控接线；自动重试要求资金开启、补扫完成和本轮储备检查通过，已有提现继续核验。重试/接线 22 项通过。专用监控、流式账本完整性与储备网关相关 112 项通过，领域和安全复审 PASS。安全复审发现的正常补扫积压造成永久暂停问题已修正为失效储备并等待，达到五分钟的积压或实际矛盾才事故暂停；现有暂停不会自动清除。

首次全流程 PG 合成验收因新迁移默认暂停而正确拒绝发布，保留 `runtime/monitor-pipeline-pg.txt`。后续在另一套明确模拟启用状态的隔离数据库验收；不能把测试夹具设置当成生产启用。当前完整仓库检查日志为 `runtime/reserve-integration-verify.txt`，检查完成前不视为通过。

生产只读配置检查确认 SMTP 通道、认证及 TLS 已配置，尚未配置人工钱包模式、付款拥有者和钱包告警收件人。检查仅记录是否配置，不读取或保存秘密值，证据 `runtime/production-readiness-presence.txt`。真实邮件送达、客户端操作及资金启用仍待验收。

继续执行检查：完整交易覆盖及补扫接线的独立规格审阅通过，根任务运行 67 项覆盖/补扫/Worker 接线测试通过。Worker 显式注入共享单源核验器并开启 deferred credit，先保留待处理义务，覆盖核验通过才完成待处理队列。整笔交易日志摘要不包含会正常增长的固化头；后续多出或缺失日志不会把旧证明当作完整证据。此结果不是生产资金启用验收。

两阶段收据已完成单独规格与安全审阅。隔离 PG16 的 8 个并发重试只生成一笔入账，重启应用容器后重放无副作用，证据 `runtime/deferred-credit/pg-result.txt`、`pg-restart.txt`。0049 已在隔离 PG16 执行，原始覆盖事实、首次证明及冲突状态受数据库保护；完整备份恢复至另一个隔离库后约束检查仍通过，证据 `runtime/coverage-migration-pg.txt`、`coverage-guards-pg.txt`、`coverage-restore-pg.txt`。未连接生产资金数据。

身份公共接口已补齐：实际账户状态、服务端管理员角色和密码恢复保护期。测试先行发现并修复 ORM 缓存身份及锁等待后的时间边界，相关 30 项测试通过，独立规格与安全复审 PASS。隔离 PG16 实际制造用户行锁等待，并在等待期间提交恢复保护记录，钱包授权正确拒绝；证据 `identity-access/pg-result.txt`。此为软件接口验证，尚未代表生产 MFA 注册及运行时接线完成。

MFA 注册/启用/中止待注册凭据的服务和 API、运行时工厂、人工提现不可变报价/冻结/领取/候选哈希/纠错/核验结算及对应 API 已实现，并分别通过规格和安全审阅。真实生产 MFA 密钥、注册及客户端操作尚未配置验收。提现候选纠错保留原始记录，实际结算哈希单列，不能将提交哈希视为付款成功。

隔离 PG16 已执行 0046、0047。8 个并发相同提现申请只冻结一次，8 个并发核验只结算一次；新容器进程重放不调用提供商、不更改储备版本。证据 `manual-payout/pg-application-result.txt`、`manual-payout/pg-restart-result.txt`。这些是合成凭据和链上证据的隔离检查。

运行时阶段完整检查 `runtime/full-verify.txt` 返回 0：API/Worker 848 通过、31 跳过；移动边界 65、基础设施 48、推送 28、机器人 9 通过。该次检查早于后续财务投影和补扫改动，不能作为这些新增改动的全仓验收。

后台财务查询和链上列表/详情 API 已关联实际充值收据或已分配提现事件；候选哈希不冒充结算，证据冲突与历史记账状态分别显示。规格和安全独立审阅均 8 项通过；前端展示尚未接线。OpenAPI 已重新导出。

持久化补扫实现已完成规格及安全审阅（各 23 项通过）。0048 增量增加游标与待处理队列表，不修改旧账；缺失迁移的预期失败已确认，加入迁移后补扫与迁移相关 38 项通过。隔离 PG16 实际迁移成功，约束拒绝非法进度/错误状态/重复交易，合法重试完成且测试事务回滚；证据 `runtime/scan/pg-migration-result.txt` 与 `pg-guards-result.txt`。补扫应用级 PG 并发验收仍待完成。PROCESSED 仅表示收款评估完成，不能作为已入账统计；独立安全审阅用真实 receipt 服务确认 REVIEW 对应零账本交易。

后台人工提现只读列表/详情已挂载 `/api/v1/admin/wallet/manual/payouts`，规格 27 项、安全 24 项通过，保留实际权限和会话校验、查询审计、严格分页及禁止缓存。

人工模式 Worker 已接运行时、只读来源和补扫服务；不再选择托管工厂。资金关闭仍核验既有提现，不激活新绑定或充值；任务不执行领取/签名/广播/取消。错误隔离先 RED 2 项后修复，任务及接线 14 项通过；规格及安全审阅 PASS。目前仍接旧监控，人工模式储备/异常监控尚待替换，不能生产启用。资源清理问题另经 RED 2 项→ExitStack 修复→15 项通过，规格/安全复审 PASS；初始化失败及 close 异常均继续清理 engine。

集成完整检查 `runtime/integration-verify.txt` 返回 0/Verification: PASS，API/Worker 908 通过、31 跳过，移动边界 65、基础设施 48、推送 28、机器人 9 通过，0048/OpenAPI/Compose 检查通过。该运行早于邮件适配完成，以及后续 UI/资源清理小改，后者另有聚焦验证，不能声称邮件已全仓验收。

后台链上面板已显示服务端财务关联状态、用户/收据/账本/意图编号及证据冲突，金额仍为原始六位字符串。RED 2 项→GREEN 5 项，规格/安全审阅 PASS，UI contract PASS。真实隔离 Chrome 页面交互通过 `runtime/chain-browser-result.txt`。通用 browser-smoke 首次因旧消息画板数量断言 59/实际63失败；改为精确匹配当前 catalog 数量并新增链上页面验证后 `runtime/browser-smoke-green.txt` PASS。Figma 沿用用户授权延期，本次没有远端节点修改；本地 registry 和 export ledger 仅记录实现状态。

邮件告警已实现真实 SMTP 适配及钱包域公开回执服务。事件校验以持久化 Outbox 原始 payload 和事件稳定身份为准，合法等级变化不阻断历史邮件；两个变级窗口先 RED 再修复，相关 33 项通过，独立规格/安全审阅 PASS。人工模式 Worker 已注入 handler，资金启用时缺收件人或 Disabled sender 拒绝启动，独立接线规格/安全审阅 PASS。尚未配置生产收件人或实际发送；此为 SMTP 模拟验收，不代表送达用户邮箱。

后续储备集成检查发现：现有 RESERVE_UNAVAILABLE 收据重放不会重试入账。正在实现公共两阶段处理及重试接口，完成前不得启用真实充值。

邮件/UI 阶段全仓检查 `runtime/mail-ui-verify.txt` 返回 0/Verification: PASS，API/Worker 935 通过、31 跳过；移动边界65、基础设施48、推送28、机器人9通过。该检查不覆盖后来完成的收据两阶段和观察截面增补；它们需单独验证和后续集成检查。

只读 `ReserveCut` 与完整 `SourceEvent` 字段增补通过规格/安全审阅，26 项聚焦测试通过。快照精确保存余额、观察编号、最大rowid、水位、固化高度、健康/有效期与digest；仅为观察截面，不是完整覆盖或储备发布证明。

仍需完成 Worker 接线、实时储备与异常转出核验、告警投递、管理端/移动端操作界面、兑换储备核验、生产配置及实际用户操作验收。尚未构建新的正式 APK 或发布更新弹窗。

没有部署本次修改，没有修改生产资金开关，没有操作 imToken 或广播真实交易。本记录不是资金启用报告。
