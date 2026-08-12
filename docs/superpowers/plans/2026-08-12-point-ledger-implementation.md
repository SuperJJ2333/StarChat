# 六合通 Phase 4 彩币账本实施计划

## 目标
交付 CAIBI 两位小数的追加写复式账本、用户转账及 0.5% 转出方手续费，以及客服上下分审批。

## 任务
1. 账本账户、交易、分录、额度策略、调整申请模型与迁移。
2. `LedgerService.post/reverse`：同资产借贷平衡、账户非负、幂等、原因码、操作者、审计和 Outbox。
3. `PointTransferService.transfer`：`max(0.01, HALF_UP(amount*0.005, 2))`，发送者额外承担手续费。
4. `AdjustmentWorkflow`：客服提交、财务复核、超阈值管理员二次审批、单笔/单日/用户范围限制。
5. API、RBAC、OpenAPI、并发和属性测试。

## 状态机
`SUBMITTED -> FINANCE_APPROVED -> (ADMIN_APPROVED) -> EXECUTED`，任一审核阶段可 `REJECTED`。低于管理员阈值的财务审核可直接进入待执行状态；执行仍为独立幂等事务。
