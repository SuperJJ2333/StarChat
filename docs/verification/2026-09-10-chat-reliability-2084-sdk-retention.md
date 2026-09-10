# Matrix SDK 与工厂账户保留验证

## 现象与复现

真实 Client 收到 M_UNKNOWN_TOKEN（hard logout 或没有 soft logout 回调）时，SDK 会清空并删除数据库。软重认证没有 refresh token 时，新 access token 不落库。另一次凭据写入失败也进入 init 的 clear 分支。账户身份仍在但内存 token 失效时，工厂此前返回空身份快照；初始化或迁移失败可能遗留打开的 SQLite 句柄。

## 根因与修改

- SDK 新增默认 false 的 preserveStoreOnInvalidToken。应用工厂启用后，失效令牌清除内存授权、停止同步并进入 softLoggedOut，保留数据库；默认行为保持兼容。
- 软重认证无 refresh token 也写入新 token，保留原 Olm pickle 和同步游标。init 异常在 opt-in 模式失败关闭但不删除数据库。
- 工厂对软登身份继续验证 MXID、deviceID、指纹与绑定；已绑定数据库身份消失时拒绝继续。迁移、SDK 初始化、SDK schema 打开失败分别关闭已获得的资源，无清库调用。

## 验收

- test/features/matrix/sdk_invalid_token_store_retention_test.dart 使用真实 Matrix Client、Mock HTTP 与真实 SQLite。断言 hard/soft invalid token 的 opt-in/default 四组合、认证请求在传输前被拒绝、无 refresh token 续登持久化、SQLite trigger 写入故障保留库和合成 Olm/会话状态。合成 fixture 不含用户消息或真实密钥。
- SDK red、token-persistence-red、init-failure-red 日志均记录预期缺陷；green 为 5 tests passed。
- 工厂四项新增回归先红后绿；factory、account_client_selection、SDK 三文件合计 68 tests passed。工厂源文件与测试分析无问题。
- SDK 单独分析有两处原有 vendor info：discarded_futures 与 curly_braces_in_flow_control_structures，均非本次修改行。
- 全部日志：docs/verification/artifacts/2026-09-10/chat-reliability-2084/accounts/sdk/。
- 未发真实用户消息，未执行 build、push、部署。SQLite 测试验证持久化边界；iOS/Android 原生 SQLCipher 与实机恢复由主任务集成验证。

## 已知环境清理限制

最早相对路径的两份合成 SQLite 被 FFI 放到 apps/mobile_flutter/.dart_tool/docs/verification/artifacts/2026-09-10/chat-reliability-2084/accounts/sdk/。之后测试改用绝对路径。原生 PowerShell 对该精确目录及文件的删除均被自动审批拒绝，已告知主任务，未绕过限制；这些文件不是用户数据库。
