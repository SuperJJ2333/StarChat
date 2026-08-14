# ADR-0003：移动端双域持久会话

**状态：** Accepted  
**日期：** 2026-08-14

## 背景

Flutter 客户端虽然把 Business Token 写入安全存储，但启动入口始终构造登录页；Matrix Client 也没有持久数据库与启动初始化，因此 APP 进程退出后无法恢复业务会话、Matrix 设备和同步状态。

## 决策

1. 采用单一启动协调器恢复 Business 与 Matrix 两个会话域。
2. Business Token 以单个版本化令牌对记录保存；该记录与 Matrix SQLCipher 数据库密钥存入平台安全存储。
3. Matrix SDK 使用 SQLCipher 持久数据库，复用账号、Access Token、设备 ID、同步游标和本地加密状态。
4. 临时网络故障进入离线已登录状态，不清除任何会话。
5. 仅在主动退出、账号封禁或服务端明确判定令牌失效时返回登录页。
6. 不保存用户密码，不降低 E2EE、设备验证、交叉签名或密钥恢复要求。
7. Business Refresh Token 轮换时重新校验用户仍为 `ACTIVE`，封禁/停用用户不能续期会话。

## 后果

- APP 重启不再创建新的 Matrix 设备，设备验证与加密会话连续。
- 启动过程变为异步，需要明确的加载、离线和本地数据库错误页面。
- 增加 SQLCipher、SQLite 和路径解析依赖，并需要 Android/iOS 真机或模拟器数据库验证。
- 退出登录必须同时处理服务端撤销与本地安全删除。

## 保护性评审要求

实现完成后必须分别执行：

- Domain Review：确认 Business/Matrix 权威边界、刷新状态机和退出补偿正确；
- Quality/Security Review：确认 SQLCipher 生效、密钥不落普通存储、日志不泄密、网络错误不会错误清除会话。
