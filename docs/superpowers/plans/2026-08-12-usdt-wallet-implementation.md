# 六合通 Phase 6 USDT-TRC20 Sandbox 钱包实施计划

## 范围
自有业务后端作为 USDT 账本事实源，SandboxCustodyProvider 模拟第三方托管商。首版只支持 USDT-TRC20，不支持 USDT 用户互转、兑换或红包。

## 状态机
- 充值：`WEBHOOK_RECEIVED -> CONFIRMED -> CREDITED`；签名校验、事件 ID 幂等、区块确认数门槛。
- 提现：`REQUESTED -> FINANCE_APPROVED -> ADMIN_APPROVED(大额) -> PROVIDER_SUBMITTED -> CHAIN_CONFIRMED`，失败进入 `FAILED`，对账不一致进入 `PAUSED`。
- 大额提现双人审批，不能由同一操作者完成两次审批。

## 不变量
USDT 使用 Decimal/NUMERIC(20,6)，与 CAIBI 隔离；钱包私钥不进入业务服务；Webhook 只接收元数据；重复或乱序事件不重复入账；所有状态改变有幂等键、原因码、审计和 Outbox。

## TDD 任务
1. 托管契约与 Sandbox 实现。
2. 钱包模型、迁移、充值签名 Webhook。
3. 提现审批与托管提交状态机。
4. 增量/全量对账及自动提现暂停。
5. API、Worker、OpenAPI 和契约测试。
