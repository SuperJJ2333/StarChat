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


## 2026-09-09 账号切换与限流修订

用户已批准修复范围；领域及 Quality/Security 评审通过。

- 密码登录响应增加可空 `matrix_user_id`，来源仅为本次通过认证的 User；刷新响应保持原契约。客户端不得把旧账号绑定继承给新登录。
- 同一客户端的登录、确认切换、取消串行执行。已知目标身份时先确认，再申请一次令牌。兼容旧服务端时，未消费令牌仅可在同一次登录尝试内暂存内存；按请求开始时间计算有效期，留五秒余量，取消、新登录或提交前立即失效。未知消费结果不可重用。
- 网络中断保留业务凭据和本地加密数据；补偿异常不覆盖原始失败。阶段诊断仅用固定编号 L01–L06，禁止原始异常文本、令牌或账号数据。
- 上游429映射为 `MATRIX_LOGIN_RATE_LIMITED`/HTTP429及数字 `Retry-After`，客户端按等待时间阻止重复交换和整段登录自动重放。服务器限流和权限校验不变。
- 新增响应字段为兼容扩展；生产补丁保留既有管理端认证与禁止缓存响应头，不做迁移。
