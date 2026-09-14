# ADR 0069 — 窗口外充值独立人工补录

日期：2026-09-13。用户明确授权“补齐超出时间窗口的人工补录流程，明确归属用户、核实未重复入账，并保留审批、幂等和审计”。Astra负责架构决策和主审，显式gpt-5.6-terra实施。状态：已接受用于实现；late_deposit_backend领域评审、late_deposit_ui独立质量/安全设计评审均已通过，Astra确认按本ADR实施并继续审实际代码。此授权不代表本轮执行生产加款或部署。

## 决策和范围

普通ADR0066充值修复与五分钟规则保持。增加独立人工补录单，不伪造历史DepositIntent，不改写旧订单/收据时间，不把同一订单用两次。适用真实已固化、已形成pending obligation但无可用普通订单的充值收据，包括付款早于建单超过五分钟。金额只能取收据，USDT六位Decimal；不增加币种转换。

新增不可变ManualDepositCase和ManualDepositDecision：创建补录单→负责人明确批准/驳回→90秒执行预检→二次确认入账。审批沿用ADR0066的唯一官方钱包owner及有效wallet grant；不是新建第二资金角色。case和decision均记录操作者、原因、核对依据、时间及幂等key/payload digest，审计与Outbox同事务。每case最多一个决定；驳回后可创建新case，旧case永不改写。不同case可引用同receipt，但最终receipt只能入账一次。

归属不能任意指定：服务端根据收款来源地址与付款区块，找到唯一有效ACTIVE/RETIRED历史WalletBinding，展示用户ID/畅聊号/昵称供管理员确认。提交user_id必须匹配该用户。执行时重新核对绑定ID/版本/区间和用户状态；无绑定/绑定多义/用户不匹配均拒绝。不以当前地址owner替代历史区块归属。金额、地址、网络、合约、配置版本、基线、异常记录、整笔交易各日志事实、最终性、时钟、储备、风险与资金门禁均沿用现有约束。正常或五分钟前移窗口内存在未消费的OPEN/EXPIRED匹配订单时，返回ORDINARY_INTENT_AVAILABLE，提示普通修复，不让人工case绕过普通订单歧义。

执行复用RepairPreview(kind=MANUAL_DEPOSIT)、RepairCommand(receipt_id唯一，intent_id=NULL)、WalletLedger.post(scope=wallet.deposit.receipt，key=receipt:<id>)和transfer_pending_to_credit。命令类型以不可变preview外键的kind为唯一权威；所有新/旧入口的重放与查询显式校验kind，跨类型同key拒绝，不新增可漂移的重复kind字段。账本、pending义务、收据信用、命令、证据审计和Outbox一次事务；网络证据在锁外获取，锁内与提交前重新核验。

收据增加nullable/unique manual_case_id FK，CREDITED归属必须intent_id XOR manual_case_id，且user_id/ledger_transaction_id非空、pending=false。普通路径不变。ORM与PG触发器同步约束：REVIEW不能提前改归属，CREDITED不可再改；manual case必须绑定同receipt/user，并有APPROVED决定。保留原reason_code和全部链事实。新增迁移0066接当前0065，仅扩展；保留历史，禁止破坏性downgrade。关联查询增加manual_case_id/attribution_kind，入账后列表显示已入账而非无订单。

锁顺序沿用budget→wallet control→owner/grant→receipt→绑定状态/绑定→risk；不可变case/decision在锁内验证。执行同key同payload返回原结果，换payload/跨kind拒绝；不同key/不同case/普通自动入账竞争同receipt只有一次信用。所有资金写入均受wallet_manual_repairs_enabled及最后grant检查保护，关闭后结果查询仍可用。

## 接口与界面

同一/admin/wallet/manual下增加manual-deposit-cases：GET /context?txid&log_index；POST /（receipt_id,user_id,reason_detail,ownership_attestation=true，Idempotency-Key）；GET /{case_id}；POST /{case_id}/decision（APPROVED或REJECTED、reason_detail、confirmed=true，Idempotency-Key）；POST /{case_id}/preview；POST /{case_id}/execute（既有RepairExecuteBody+Idempotency-Key）；GET /operations/{operation_id}。静态operations路由需先于动态case路由。所有读写均需owner有效钱包验证。

后台充值补入账弹窗提供“超时/无匹配订单：人工补录”入口。页面展示链上收据、唯一归属用户、原订单仅供参考、明确未入账检查、填写依据、提交审批、批准/驳回与最后确认。刷新可恢复case；结果未知只查同operation，404后保留原key重新预检，不自动重发资金请求。不将预检或批准显示成已入账。

## 验收与回退

覆盖真实场景：第一笔可走普通订单；第二笔早627秒无独立订单可由独立case归属同用户、审批后入账，旧订单完全未改。对未审批/驳回/错用户/历史绑定歧义/同receipt重复/旧路径并发/过期证据/撤销grant/停用开关/审计或Outbox失败做拒绝或全事务回滚测试。新增表与收据触发器做真实隔离PG并发及不可变验证；环境缺失明确记录，不当作通过。

回退关闭新写受理并回退应用候选，保留扩展表/收据列/审计/账本。已信用不可删除，纠错另走批准的关联冲正。未进行生产实际信用、部署或真机测试。
