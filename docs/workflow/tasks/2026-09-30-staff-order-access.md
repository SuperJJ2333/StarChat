# 客服订单权限报错调查

## 范围与状态

- 用户报告指定客服账号订单提醒、案件列表、历史读取失败，要求解释原因。本记录独立于首次开通邮件和钱包订单撤销任务。
- 使用既有 codex/wallet-alert-only-payout-void 工作树；本次仅拥有本记录和 ignored 只读诊断脚本，无产品代码、权限或生产状态修改。
- 已完成生产只读调查；未伪造会话、解除保护期或修改角色。

## 证据

- 实际 API 902eaefc、worker 00c0e109。指定账号 ACTIVE，SUPPORT_AGENT 与 FINANCE_SUPPORT 均存在；邮箱开通摘要匹配；管理会话、令牌族及设备有效。
- 账号存在 WITHDRAWAL / PASSWORD_RESET 保护记录：2026-09-30 15:21:39.717353 +08 开始，2026-10-01 15:21:39.717353 +08 结束。
- SupportOrderSessionAuthorizer 的 require_support_order_actor 在角色与开通校验前调用 require_wallet_actor；该函数命中恢复保护返回 WALLET_RECOVERY_HOLD / HTTP403。
- 充值 pending、events、history 路由共用此授权依赖。因此该账号的个人恢复保护也阻止客服订单读取。
- 前端 admin-order-notifications.js 将所有403显示为权限失效；admin-recharge-panel.js 将列表/历史失败笼统归为权限或网络/财务权限。文案未反映真实恢复保护原因。
- 诊断只读事务 SET TRANSACTION READ ONLY，纯摘要比较，不调用可能迁移开通摘要的授权函数；不输出联系地址、验证码、密码或令牌。

## 结论与下一步

- 根因为密码重置后24小时恢复保护与客服订单授权的耦合；不是客服角色丢失、邮件未开通或登录过期。
- 当前策略下保护期到期后刷新重试，或由另一名已授权且不在保护期的财务客服处理。
- 若后续要求调整保护范围，须按受保护RBAC/钱包规则形成批准设计及领域、安全审查；不能直接删保护记录。
- 诊断脚本：docs/verification/artifacts/2026-09-30/diagnose_staff_order_access.py。调查约在用户本次反馈后进行；未记录精确阶段起止，不估算耗时。