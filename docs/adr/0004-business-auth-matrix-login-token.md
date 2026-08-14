# ADR-0004：Business 认证与 Matrix 一次性登录令牌

**状态：** Accepted
**日期：** 2026-08-14

## 背景

Business 用户密码使用单向哈希保存；Matrix 账号由异步 Worker 在邮箱验证后创建，使用独立的服务端派生凭证。客户端若复用业务密码登录 Matrix，新注册用户必然认证失败。把业务明文密码写入 Outbox、数据库或 Matrix 同步流程会破坏凭证边界。

## 决策

1. 用户密码只提交给 Business API。
2. Matrix 账号继续由 Worker 使用专用派生凭证幂等创建。
3. Business 登录成功后，受认证接口通过 Synapse 管理 API 为当前稳定 MXID 签发短期、单次 Matrix Login Token。
4. Flutter 使用 `m.login.token` 登录 Matrix；已恢复持久 Matrix 会话时不申请 Token。
5. Matrix Token 不持久化、不记录日志、不进入 Outbox 或分析事件。
6. Token 认证失败执行既有半登录补偿；网络错误保留 Business 会话并允许重试。
7. 不改变 Matrix SQLCipher、E2EE、设备验证、交叉签名和加密备份规则。

## 后果

- Business 和 Matrix 不需要共享用户密码。
- 新注册、既有账号和多设备登录使用统一流程。
- Business API 增加受认证 Token 交换端点与 Synapse 管理契约测试。
- Synapse 管理凭证仍只能存在于受控服务环境。

## 评审要求

实现必须通过 Domain Review 与 Quality/Security Review，验证身份绑定、单次使用、日志脱敏、半登录补偿和 E2EE 不降级。
