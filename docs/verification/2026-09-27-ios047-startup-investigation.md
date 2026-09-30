# iOS 0.4.7 覆盖更新后本地会话读取失败

用户事实：覆盖更新后出现“应用启动时无法读取本地会话，请解锁手机后重试”；解锁、重试、重开均不能恢复。尚无完整build、iOS版本和底层cause/status。本记录只调查，不修改认证/E2EE恢复，也不清用户数据。

## 公开构建的确定事实

已核对公开2173源 `9eb41e8fdcc2e00db52904c0ffbee746fdb4e178`，包含 `2d463207` 重启会话修复和 `294629a3` 身份归档恢复修复。v0.4.7另有暂停的2172，只有版本名不能确定用户具体构建。

`installation_startup_gate.dart` 捕获启动异常，调用 `sessionFailureMessage(... stage:startup)`。公开源的 `session_failure.dart` 不识别 `MatrixLocalIdentityPreflightException`；factory将部分metadata/安全存储异常包装为 unreadable，并丢失原始错误类型。数据库/迁移/本地身份预检也可能包装为该异常，随后落入unknown通用提示“请解锁”。提示本身不能证明设备锁定。

直接未包装的 -25308 / PROTECTED_DATA_UNAVAILABLE 有“设备安全存储暂不可访问”的分类；-34018 有安全存储权限分类。包装后这些差异也可能丢失。当前仓库同一分类缺口仍存在。

原生会话与数据库密钥主要采用 AfterFirstUnlockThisDeviceOnly，并迁移旧条目；诊断salt/install ID仍有插件默认WhenUnlocked读取。因此不能概括为所有存储都可在首解锁后读取。重试确实重新执行启动检查与client创建。

## 与 L04/L07 的关系

L04、L07分别指 matrix_login / account_storage 阶段，不能单独作为根因码。旧2144日志中确有身份fingerprint不连续问题，但该日志早于本次覆盖更新，不能当作用户此次设备证据。2173已包含相关修复，仍可能在不同的安全存储、数据库密钥、账号槽/绑定或未完成迁移状态上失败。

用户“已解锁且重试无效”削弱临时保护数据不可访问的解释，更符合持续预检/读取问题；仍无法凭提示确定是哪一种。公开企业包签名Team/AppID/访问组及用户接受的注入记录已核对，不能断言换Team或注入就是本次根因。

## 后续最小信息

需要准确build、iOS版本、更新前该安装是否正常登录/读旧消息，以及在同次失败中采集的闭合预检分类或OSStatus。不要传令牌、密码、数据库、密钥或用户媒体。不要以卸载、清钥匙串或重建Matrix身份作验证。后续若修复提示/分类，需要独立认证与E2EE领域审查；恢复动作取决于具体状态，不能统一清除。

证据来源：本任务只读代理调查、公开构建源及原目录 `docs/verification/artifacts/2026-09-25/ios2173-distribution/` 的静态签包记录；尚无用户设备实时失败日志，未声明真机根因已确定。
