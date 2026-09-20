# 钱包与资金操作索引

**Current index · 2026-09-20**。这里只合并入口，不修改资产公式、鉴权、审批或业务流程；专题中的现场配置必须重新核对。

| 场景 | 文档 |
| --- | --- |
| 日常及演练 | [Sandbox日结](wallet-operations.md)、[Sandbox边界](wallet-sandbox-application.md)；不能作为生产资金启用依据 |
| 人工钱包 | [人工TRON出款](manual-tron-funding.md)、[独立能力开关](wallet-independent-activation.md) |
| 故障恢复 | [钱包事故恢复](wallet-incident-recovery.md)、[窗口外充值补录](manual-deposit-cases.md) |
| 地址/观察 | [地址登记](wallet-address-registration.md)、[TRON只读观察](tron-watch-only.md) |
| 鉴权 | [MFA设置](wallet-mfa-setup.md)、[红包/转账支付密码](chat-payment-pin.md) |
| 账务核对 | [日流水预览](wallet-daily-ledger-preview.md)、[充值自动兑换](deposit-auto-conversion.md) |

部署共性归[生产工作流](admin-production-workflow.md)；旧客户端联合发布、钱包绑定、60分钟验证、关闭真实资金预检及重采样的当次操作移入[历史归档](../archive/2026-09-20/README.md)。旧镜像、迁移头、能力关闭要求不能直接用于当前生产。

财务状态以业务API为准；不直接改账本或根据Matrix消息修改余额。资金写、幂等、审计、Outbox、操作人权限及已有审批边界全部保留。归档不授权任何资金操作或降低认证要求。
