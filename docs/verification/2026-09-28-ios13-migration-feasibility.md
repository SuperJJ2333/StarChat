# iOS 新签名团队迁移可行性核查（2026-09-28）

## 输入与边界

- 用户回传 `畅聊 ChatFlow (13).ipa`，希望更新 iOS 下载与安装入口，随后选择先制定新团队迁移方案。
- 用户确认：旧签名团队 `ZXB3TS7QD4` 已不可用；至少一台旧团队签名的 iPhone 仍能打开畅聊并读取旧聊天；现有 iOS 用户没有在 App 之外保存 Matrix 恢复密钥。
- 本次仅检查包体、冻结源码、现网只读状态及公开平台规范。没有在 iPhone 上安装新包，没有上传或切换生产下载入口。

## 证据与结论

| 项目 | 已确认事实 | 迁移影响 |
| --- | --- | --- |
| 签名 | 已发布 `(12)` 为 Team `ZXB3TS7QD4`，回传 `(13)` 为 `A9HAF6NT6S`；Keychain access group 前缀随之改变。[签名复核](artifacts/2026-09-28/ios13-distribution/review/report.md) | 新团队没有访问旧团队 Keychain 项的授权。静态验签不证明覆盖安装、App 沙盒连续或旧聊天可读。 |
| 包身份 | `(13)` 仍是旧 Bundle ID `com.liuhetong.liuhetongMobile`、`0.4.20/2189`，签名 `application-identifier` 为 `A9HAF6NT6S.com.cd-rail.zhct`。[包体验证](artifacts/2026-09-28/ios13-distribution/ipa-verification/report.md) | 当前包不是一个可与旧版并装、身份一致的新渠道包；同版本不触发已安装 2189 的更新弹窗。 |
| 本机密钥 | [IOSSecureSession.swift](../../apps/mobile_flutter/ios/Runner/IOSSecureSession.swift) 使用默认 Keychain 组；[session_store.dart](../../apps/mobile_flutter/lib/core/session_store.dart) 保存业务会话、Matrix 身份和 SQLCipher 数据库密钥。[local_identity_preflight.dart](../../apps/mobile_flutter/lib/features/matrix/local_identity_preflight.dart) 对已有加密库而缺密钥的状态失败封闭。 | 即使跨团队覆盖后主容器保留，旧数据库也不能仅凭重新登录打开。卸载旧版可能破坏唯一可读副本。 |
| 2189 恢复 UI | 冻结源码 `e9b5349` 的 [MatrixSecurityPage](../../apps/mobile_flutter/lib/features/matrix/matrix_security_page.dart) 没有生产导航入口、无恢复密钥导出；[MatrixVerificationPage](../../apps/mobile_flutter/lib/features/matrix/matrix_verification_page.dart) 只从该不可达页面进入。`saveEncryptedRecoveryKey` 与 `bootstrapOnlineBackup` 没有生产调用点。 | 仍可工作的旧版当前无法由用户经 App UI 执行受信任设备迁移或导出恢复密钥；不能承诺已存在完整在线密钥备份。 |
| Matrix 密钥分享 | [SDK KeyManager](../../apps/mobile_flutter/third_party/matrix/lib/encryption/key_manager.dart) 会按缺失的房间会话请求密钥；旧设备自动转发仅在持有该密钥且新设备已验证、未封禁等条件下发生。 | SAS 验证自身不会批量转移历史密钥；必须在真机抽查早期消息解密，并核对备份实际存在及解密密钥可用。 |
| 线上 | [只读前检](artifacts/2026-09-28/ios13-distribution/preflight/report.md)：iOS `0.4.20/2189` 仍指向 `(12)`；Android `0.4.21/2190`。 | 本轮尚未发布 `(13)`，旧入口仍可用。旧 profile 到期为 2026-12-03 10:06:44 +08，应优先保全旧设备、安排决策。 |

Apple 的 Keychain 组权限及跨团队 App Transfer 条件见 [Keychain access groups](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)、[DTS 跨团队迁移讨论](https://developer.apple.com/forums/thread/706128)、[App transfer criteria](https://developer.apple.com/help/app-store-connect/transfer-an-app/app-transfer-criteria)。DTS 的旧团队先发布桥接版流程要求旧团队参与，不能直接套用在此次企业重签且旧团队不可用的场景。Matrix [Client-Server API v1.18](https://spec.matrix.org/v1.18/client-server-api/) 将设备验证、密钥分享和加密备份列为不同流程；服务器备份不是自动存在的明文历史。

## 可行性判定

在“旧团队不可签新包、用户没有外存恢复密钥、旧 2189 无可达导出/验证入口”三项条件同时成立时，**当前没有已验证的全量无损迁移方法**。新团队可以发行独立 Bundle ID 的并装 App，供测试与新用户使用，或让既有用户在明确知晓旧历史可能无法读取后自愿重新开始；这不是旧本地聊天迁移。实际可恢复范围只有在真机证明现存 Matrix 备份和解密密钥可用后才能逐账号判定。

调查阶段的建议是暂停 `(13)` 官方入口切换；此后用户在获知上述损失风险后明确选择**只发布新团队包并直接替换下载/安装入口**，该发布决策见[任务记录](../workflow/tasks/2026-09-28-ios13-distribution.md)。这一选择不改变技术结论：不得把“重新登录”“SAS 完成”或静态验签写成历史恢复成功；仍应保留可读取旧聊天的 iPhone 与旧不可变包，勿主动卸载或清除数据。
