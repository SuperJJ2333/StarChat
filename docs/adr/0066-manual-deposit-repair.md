# ADR 0066 — 追加式人工充值补入账与提现核对

日期：2026-09-10。产品授权：本轮全部需求实施与发布授权；实现策略由主任务确认。金融上线仍以独立领域审查、质量安全审查及 PostgreSQL 并发验证通过为门槛。

状态：已接受；独立领域、质量/安全审查及真实隔离 PostgreSQL 并发/不可变约束验证已通过，相关修复完成复审。证据见[资金验证](../verification/artifacts/2026-09-10/admin-financial-completion/verification.md)与[集成交付记录](../verification/2026-09-10-admin-completion.md)。这是实现与发布评审结论，不代替真实付款归属的管理员业务确认；本轮未执行指定生产收据的实际补入账。

## 决策

人工补入账由现有唯一官方钱包管理员及有效的 60 分钟 wallet grant 执行。保持既有单 owner 认证模型，不扩展第二位资金操作者。代码发布前的领域与安全双审分别记录；它们不是第二位业务审批人。finance.review 或 audit.view 不取得补入账权限。

所有写入要求明确业务二次确认、原因枚举、说明、90 秒不可变预检摘要、版本、operation_id 与 Idempotency-Key。退出/重新验证仅查询原命令，不重放写请求。独立配置 wallet_manual_repairs_enabled 控制新命令受理，关闭后预检、结果查询仍保留。

一般已过期订单仅在固化区块落在原订单时间窗内、历史绑定唯一有效、付款地址/官方地址/配置/网络/金额一致时允许人工信用。原 EXPIRED 状态、created_at/expires_at/closed_at 和原收据原因均保留。仍 OPEN 的订单按既有状态机关闭为 FULFILLED。

PAYMENT_BEFORE_ORDER 是独立、明确的人工业务例外：区块时间严格早于订单创建时间，差值最多 300 秒；操作者须明确确认该付款属于所选订单。该确认固化为 payment_attestation 和原因说明。它不宣称事发时的服务器时钟偏差已被证明，也不改写时间。全部正常时间窗及前移五分钟窗口中的同额/同来源候选参与歧义检查，不能通过选择某个 ID 消除歧义。超过五分钟、重绑关闭、历史绑定不唯一、风险冻结、资产/网络/地址不一致一律拒绝。当前可信时钟健康由独立监测提供，无监测默认拒绝。

完整固化交易在锁外获取，锁内复核其政策、来源、网络、区块、每条已记录日志事实、歧义和新鲜度。遵循预算、钱包控制、操作者、订单/绑定锁顺序，账本采用现有 WalletLedger.post；待处理义务转信用采用 ledger.wallet_obligations.transfer_pending_to_credit，使用现行 reserve_policy。同一事务写收据信用、命令、平衡分录、审计和 Outbox，提交前再核验 grant、预检期限、链证据及可信时钟。

收据现有 network/contract/txid/log_index 与 intent 唯一约束继续生效，新增命令 receipt_id/intent_id 唯一约束。预检/命令追加不可变，PostgreSQL 迁移增加 UPDATE/DELETE 拒绝触发器。迁移仅扩展，不删除历史表。

转出流程仅为已 CLAIMED/UNKNOWN 且属于该 owner 的真实提现单增加经预检的候选 txid。复用 ManualPayoutService.submit_txid，候选与人工命令在同一事务提交；原有后台 reconciler 继续完整候选核验并结算。该入口不签名、不广播、不创建新转账，也不允许转出走充值。

## 回退与结果未知

关闭新命令功能开关，保留全部案件和结果查询；不回退数据库快照、不删除账本和审计。超时按原 operation_id 查询。成功入账的纠错只能走另行批准的关联冲正/补偿。尚未受理或证据过期的请求必须重新预检和业务确认。
