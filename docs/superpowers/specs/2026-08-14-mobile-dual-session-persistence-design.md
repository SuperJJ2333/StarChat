# 六合通移动端双域持久会话设计规格

**状态：** 已确认，待实施  
**日期：** 2026-08-14  
**范围：** Flutter 移动端、Business API 会话、Matrix SDK 本地会话

## 1. 目标

用户完成一次 Business API 与 Matrix 登录后，关闭、杀死或重新启动 APP 均保持登录状态。只有以下情况返回登录页：

1. 用户主动退出登录；
2. 业务账号被封禁或停用；
3. Business Refresh Token 已撤销、过期或轮换失败并被服务端明确判定无效；
4. Matrix 服务端明确判定持久会话已经失效。

临时断网、超时、DNS 故障和服务暂时不可用不得清除本地会话。

## 2. 已确认方案

采用方案 A：双域持久会话恢复。

- Business Access Token 与 Refresh Token 存入平台安全存储。
- Matrix 使用 SDK 的持久数据库保存账号、设备、同步位置、房间缓存和加密状态。
- Matrix 数据库使用 SQLCipher；数据库密钥随机生成并只存入平台安全存储。
- APP 启动由单一 `SessionBootstrapController` 协调两个域，不再无条件显示登录页。
- 不保存用户名密码，不通过保存密码实现自动登录。

## 3. 架构边界

### 3.1 Business 会话

`BusinessApiClient` 负责：

- 登录并原子保存 Access/Refresh Token；
- 使用 Refresh Token 调用 `/api/v1/auth/refresh` 并原子替换令牌对；
- 对认证请求执行一次受控刷新后重放；
- 区分认证失效与网络故障；
- 主动退出时尽力撤销 Refresh Token，然后清理本地令牌。

任何刷新失败都不得直接清理会话。只有服务端返回明确的 401 认证失效、账号封禁/停用结果时才清理；网络异常进入离线已登录状态。

令牌对以一个版本化 JSON 记录写入单个安全存储键，避免 Access Token 与 Refresh Token 只更新其中一个。现有双键数据在首次启动时迁移，迁移成功后删除旧键。Business API 的刷新流程必须重新查询用户状态；非 `ACTIVE` 用户不得获得新令牌。

### 3.2 Matrix 会话

APP 在 `runApp` 前完成 Matrix Client 创建和 `init()`：

- 使用固定客户端数据库名，避免每次启动创建新设备数据库；
- SQLCipher 密钥由安全随机数生成，不写入源码、日志或普通偏好设置；
- 已登录时复用原 Matrix Access Token、设备 ID、同步游标和本地加密材料；
- 未登录时才执行密码登录；
- 启动同步遇到网络异常时保留 Matrix 会话；
- Matrix 明确返回未知/失效 Token 时，进入会话失效处理。

服务端仍不得获得恢复密钥、房间密钥、消息明文或附件明文。

### 3.3 启动协调器

`SessionBootstrapController` 只通过公开接口协调两个域，状态为：

- `loading`：读取安全存储、打开 Matrix 数据库并判断会话；
- `authenticated`：两个域均可用，进入主页；
- `offlineAuthenticated`：持久会话存在，但当前网络不可达，进入主页并显示重连状态；
- `unauthenticated`：没有完整会话或令牌被明确判定失效，显示登录页；
- `fatalError`：本地安全存储或加密数据库不可恢复，显示可操作的错误页，不静默删除数据。

启动恢复顺序：

1. 初始化 Matrix 加密数据库；
2. 读取 Business Token；
3. 判断 Matrix `isLogged()`；
4. Business Access Token 可用则保留，否则尝试刷新；
5. 启动 Matrix 同步；
6. 根据结果进入已登录、离线已登录或未登录状态。

Business 与 Matrix 持久记录必须包含相同的稳定用户标识映射；检测到两个域属于不同用户时进入 `fatalError`，不得自动拼接两个账号的会话。

## 4. 正常登录与半登录补偿

正常登录按以下顺序执行：

1. Business API 密码登录；
2. Matrix 密码登录；
3. Matrix 初次同步完成；
4. 两个域均成功后进入主页。

若 Business 成功而 Matrix 明确认证失败，客户端撤销刚签发的 Business Refresh Token并清理本地 Business Token。若 Matrix 仅发生网络故障，不把它误判为密码错误，保留 Business 会话并允许用户重试 Matrix 登录。

## 5. 主动退出

退出操作必须清空导航栈，且按以下顺序执行：

1. 尽力调用 Business `/auth/logout` 撤销当前 Refresh Token；
2. 调用 Matrix logout；
3. 清除 Business 安全存储令牌；
4. 清除 Matrix 本地账号会话、数据库缓存和本设备加密材料；
5. 保留与其他账号无关的应用设置；
6. 返回登录页。

网络不可用时，服务端撤销可能失败，但本地退出仍必须完成；服务端 Refresh Token 按既有有效期和轮换策略最终失效。

## 6. 用户体验

- 启动期间显示微信风格品牌启动/加载页，避免登录页闪现。
- 离线恢复后可以进入已有本地缓存页面，并在顶部显示“网络不可用，正在重连”。
- 不向用户显示 Token、Matrix 设备密钥、数据库密钥或内部异常堆栈。
- 会话失效提示为“登录状态已失效，请重新登录”。
- 主动退出需要二次确认，按钮位于“我 → 设置 → 退出登录”。

## 7. 安全要求

- Access Token、Refresh Token、SQLCipher 密钥只允许进入平台安全存储。
- 日志不得包含 Token、密码、SQLCipher 密钥、恢复密钥或消息正文。
- Refresh Token 轮换写入必须避免只保存一半令牌对。
- 不允许因网络异常自动退出用户。
- 不允许通过关闭 E2EE、创建临时 Matrix 设备或保存用户密码实现恢复。
- 主动退出后旧设备数据库不得继续提供已登录访问。

## 8. 测试与验收

必须采用测试先行，并覆盖：

1. 首次启动无会话显示登录页；
2. 完整会话启动直接进入主页，登录页不闪现；
3. Access Token 失效且 Refresh Token 有效时自动轮换；
4. Refresh Token 明确无效时清理会话并显示登录页；
5. 被封禁/停用用户无法刷新并返回登录页；
6. 启动断网时进入 `offlineAuthenticated`，不删除会话；
7. Matrix 设备 ID 在进程重启前后保持一致；
8. Matrix 本地数据库确认为 SQLCipher，而非明文 SQLite；
9. 主动退出后两个域的本地会话均被清除；
10. 两台雷电模拟器分别登录 `liuhetong_test01` 与 `liuhetong_test02`，杀死并重启 APP 后仍保持各自登录；
11. 两个测试账号完成搜索、好友申请、接受和双方通讯录刷新。

## 9. 明确不做

- 不保存或自动填充账号密码；
- 不新增“记住密码”开关；
- 不允许永久有效的 Access Token；
- 不改变 Business API 与 Matrix 的权威边界；
- 不在本次修改中改变 E2EE、交叉签名或恢复密钥协议。
