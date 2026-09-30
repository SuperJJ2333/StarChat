# 链上数据源短暂读取超时记为 T2，并修正储备发布时效窗口

日期：2026-09-28。状态：本次用户已批准业务策略；实现、领域及质量/安全审查和生产验收分别留证。

## 背景与证据边界

用户提供的事故时间线显示：2026-09-28 04:02:31（香港时间）`MANUAL_SOURCE_UNAVAILABLE` 开启，04:07:44 起反复产生 `UNACKNOWLEDGED_P0`，12:53:37 记录 `condition_cleared`，但当时事故仍为 `OPEN`。现场进一步核实：04:00:46 TronGrid 区块头请求出现 `ConnectError`；04:00:51 源检查仍为 healthy、`solid_head_age_ms=120219`，但 `publish_manual_reserve` 仍用固定 120 秒比较，而 worker 的数据源窗口配置为 360 秒。04:00:52 由此产生另一项 `MANUAL_MONITOR_UNAVAILABLE` 并首次暂停钱包。04:02:31、04:06:23、04:07:23 的三次 SQLite 读取报 `SOURCE_READ_BUDGET_EXPIRED`，04:02:33 observer 已为 `SOURCE_MATCHED`；预算耗尽究竟由锁等待还是 I/O 引起尚未确认。调查时两起事故已结案，钱包拥有者于 12:54:20 单独恢复，控制标志已解除；另有一项 `MANUAL_BACKING_DEFICIT` P1 提醒，在 `manual_liquidity` 策略下不阻断。这些是该次读回事实，不代替后续生产读回。

现行人工监控把源读取路径上的任何异常归为 `MANUAL_SOURCE_UNAVAILABLE` P0 并设置全局暂停；事故模型、查询、API、告警投递和后台等级筛选只接受 P0/P1。已有 `MANUAL_SOURCE_UNHEALTHY` 是另一条 P1 提醒规则，不以名称相似性扩大本决策范围。

## 决策

1. 仅当人工钱包监控收到已识别的 `FundingSourceError('SOURCE_READ_BUDGET_EXPIRED')`，在保留 `MANUAL_SOURCE_UNAVAILABLE` 事故代码的同时记录等级 `T2`。持久化、API 响应、筛选及后台页面均原样显示 `T2`；不借用 P1，也不将普通异常、源格式错误、身份不匹配或进度回退改级。泛化的 `SOURCE_UNAVAILABLE_OR_MALFORMED` 不能证明是短暂超时，继续按 P0 处理。
2. 这条精确匹配的 T2 信号不调用 `apply_manual_pause`，不新建全局钱包暂停或安全限制，不因其未确认而每五分钟触发 P0 升级。首开、复发和等级变化仍保留事故、审计和 Outbox 事件；告警载荷只含允许的事故标识、代码及等级。
3. T2 是**记录级别和全局控制动作**的调整，不是数据可信度豁免。源读取失败的检查不发布储备、不接受过期快照、不自动入账、不结算出款；任何需要新鲜链上证据、对账、覆盖范围、储备或提交时复核的资金操作仍按原规则拒绝。单源不可用时停止新入账与出款结算的 ADR-0013 约束继续有效。T2 不自动清除已存在的暂停、限制或其他事故，也不触发自动恢复。
4. `MANUAL_MONITOR_UNAVAILABLE`、未识别的源读取异常、`MANUAL_SOURCE_INVALID`、账本/覆盖/储备异常、出款不确定、告警送达故障及其他阻断代码保持原有分级与暂停逻辑。精确的非阻断判断同时核对 `fingerprint=manual-reserve:MANUAL_SOURCE_UNAVAILABLE`、代码、`subject_id=global` 和 `severity=T2`；禁止仅按 T2 等级豁免任意事故。
5. 修正储备发布中的固定 120 秒检查，使它采用已校验的 `max_age_ms` 和快照 `fresh_until_ms`，与监控数据源实际配置窗口一致；仍在提交前验证新鲜度，过期原子回滚。提现执行处独立的 **120 秒储备时效门槛不变**，其他资金操作各自的时效、储备和对账检查不因监控窗口扩大。此修复针对首次误报 P0 的已定位路径。
6. 对本次已定位的源读取事故，使用受限、可重放的应用命令按事故 ID、generation 和预期 version 原子改级，记录真实 actor、固定原因码、幂等键、审计及 Outbox。旧的 P0 开启/升级时间线和已排队告警载荷保持不可变；重复执行返回同一结果，版本或目标不符即拒绝。不批量重写其他历史事故，不直接修改账本、控制开关或旧事件。已结案状态保留，不重新开启或自动恢复钱包。

## 兼容、回退与验收

`wallet_incidents.severity` 已为 `String(2)`，可容纳 `T2`；实施前核对生产实际 schema 与迁移 head。API 枚举、只读报表、告警消费者和旧版页面的兼容性必须逐一验证。若回退代码，须继续能够读取和投递已经持久化的 T2 事件；不可用旧的 P0 规则自动重开、重新升级或重置此事故。回退仅切换已冻结的兼容候选，保留事故、审计和 Outbox，不做破坏性降迁移。

先以失败用例证明源暂不可用不再触发全局暂停，同时证明其他危险代码仍暂停、新鲜证据门槛仍拒绝不安全资金写。再验证 T2 的持久化/API/后台展示、历史定向改级、并发幂等、旧 P0 告警重放及 P0 升级终止。完成规格符合性审查后，再做领域与质量/安全审查，按现行生产发布流程核对实际镜像、配置、schema、备份、回退和公网读回。

参考：[ADR-0013](0013-trongrid-single-source-manual-payout.md)、[事故简化设计](../superpowers/specs/2026-09-08-wallet-incident-simple-workflow-design.md)、[实施计划](../superpowers/plans/2026-09-28-wallet-monitor-t2.md)。
