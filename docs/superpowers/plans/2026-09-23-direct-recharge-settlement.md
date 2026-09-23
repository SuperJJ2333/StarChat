# 已核验充值客服直发实施计划

2026-09-23 用户明确批准将已由系统核验到账的充值改为认领客服直接下发；关联主任务客服工作台。范围和受保护决策见 [ADR-0084](../../adr/0084-verified-recharge-direct-settlement.md)。

1. 先以已核验订单经 prepare/execute 无需独立审批的失败用例固化需求，并覆盖通用财务边界。
2. 增加财务公开窄接口，保留通用调整审批、全局锁、付款回执互斥、订单认领、幂等、审计与事务 Outbox；保持旧绑定/旧执行恢复兼容。
3. prepare/列表补充审批要求及冻结结算快照字段；主任务负责 UI/OpenAPI 接线，执行前真实展示冻结金额。
4. 跑充值、到账凭证、账本专项，主任务协调全量证据复用和独立领域→质量安全审查。
5. 主任务按已授权范围部署，子任务不部署。无迁移，回退保留无 reviewer 的已执行记录登记兼容。

文件所有权：本子任务 modules/recharge/{workflow,execution,service}.py、modules/ledger/adjustments.py、钱包专项测试及本任务独立文档；不编辑 main.py、API 契约、frontend 或共享 current-state。
