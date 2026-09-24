# v0.4.7/2172 iOS 企业包分发门禁（2026-09-24）

## 结论与范围

本任务收到用户回签 IPA 和分发授权，但截至 17:21 HKT 只做了本地及生产只读核验，**本任务没有执行任何生产写入**。IPA 的签名 App ID 与实际 Bundle ID 不符，不能据静态检查声明可安装；签名与描述文件均缺少生产 APNs 权限。另一并发流程在审计期间将同一文件、manifest、下载页和 iOS 设置部分写入生产。用户表示将暂停该流程并通知，未收到暂停完成通知前不可写生产。

## 回签包身份

| 项 | 核验结果 |
| --- | --- |
| 用户提供路径 | `D:\pythonProject\outsource\StarChat\docs\verification\artifacts\2026-09-24\android-047-ios-ipa\ios\ChatFlow-0.4.7-build2172.ipa` |
| 字节数/SHA256 | 61,434,769 / `12258dac74ace99c7d462b5a50ec99122b5d45861e753715e27c26fc6c0b53f2` |
| `CFBundleIdentifier` | `com.liuhetong.liuhetongMobile` |
| 版本/构建/iOS 下限 | `0.4.7` / `2172` / `16.0` |
| 描述文件和 Runner 已签权益 `application-identifier` | `ZXB3TS7QD4.cn.edu.buaa.bhpan.fileProvider`，与实际 Bundle ID 不匹配 |
| 生产 APNs | 描述文件及 Runner 已签权益都没有 `aps-environment` |
| 签名团队/Keychain | 团队 `ZXB3TS7QD4`；Keychain 群组与旧企业包重叠，但不能由此证明可覆盖安装或保留数据 |
| 真机安装 | 本任务没有可用 iPhone 安装证据；不能将包视作通过安装门禁 |

Apple 的 [安装失败排障文档](https://developer.apple.com/library/archive/technotes/tn2319/_index.html)记录了 App ID 权益、描述文件和已安装应用身份不符导致安装/升级拒绝的情形；[APNs 注册文档](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns?changes=_1)说明缺少正确签名权限时注册可能失败；[APS 权益文档](https://developer.apple.com/documentation/bundleresources/entitlements/aps-environment?changes=_7)明确该权限同时用于 UserNotifications 与 PushKit。实际设备安装及通话效果仍需用重新签名后的包测试。

### 无生产 APNs 时的功能范围（源码推断，未做真机验收）

| 场景 | 推断 | 关键实现 |
| --- | --- | --- |
| App 前台、Matrix 已连接时主动或接听语音/视频通话 | 有望工作，WebRTC 媒体不以 APNs 为建立连接的前置条件 | `apps/mobile_flutter/lib/features/matrix/matrix_call_adapter.dart:292-372,395-440`，`apps/mobile_flutter/lib/features/matrix/call_wakeup_client.dart:133-147` |
| App 在后台或已被系统结束时接收来电 | 不能可靠唤醒或显示来电；PushKit VoIP token/推送依赖生产 APNs | `apps/mobile_flutter/ios/Runner/IOSCallsBridge.swift:43-48,160-183` |
| App 在后台或已被系统结束时接收聊天提醒 | 不能可靠接收系统远程通知；APNs token 用于注册 Matrix pusher 和 Sygnal | `apps/mobile_flutter/ios/Runner/AppDelegate.swift:100-103,137-147`，`apps/mobile_flutter/lib/features/push/native_apns_push_token_provider.dart:61-75`，`apps/mobile_flutter/lib/features/push/matrix_pusher_service.dart:118-163` |
| App 前台且 Matrix 同步正常时接收聊天消息 | 仍可通过 Matrix 同步与本地提醒路径收到消息 | `apps/mobile_flutter/lib/features/matrix/matrix_notification_event_source.dart:30-34,69-85`，`apps/mobile_flutter/lib/app_home.dart:903-925` |

上述四项全部以 IPA 能在目标 iPhone 上安装并启动为前提；当前签名 App ID 错配使这一前提尚未成立。

## 生产只读快照

以下为 **2026-09-24 17:21 HKT** 快照，另一流程可能继续变化，不可作为回退写入的当前 CAS 前态。

| 对象 | 当时状态 |
| --- | --- |
| iOS IPA | `/opt/starchat/frontend/downloads/ios/ChatFlow-0.4.7-2172.ipa`，61,434,769 字节，SHA256 与用户文件一致；非本任务上传 |
| manifest | 857 字节，SHA256 `62c754a3d3cc6ae998a0fd29cfd1b8f860e4e62709ca2e3c03a886b366331084`，指向新 IPA；非本任务写入 |
| 下载页 | 3,993 字节，SHA256 `6154d712d8fff891bf78e37453cfe699ccc703f977504aa4a0d4269bff73f710`，显示 0.4.7；非本任务写入 |
| 首页 `admin-home.js` | 21,722 字节，SHA256 `fea02e76c21772eb7dfc4c989da483f3d7be9fb2429061cc3b34298cd46a7674`，仍显示旧 2144 |
| iOS 更新设置 | `latest_version=0.4.7`、`latest_build=2172`、最低支持构建号 3、URL 为 HTTPS 安装页；本次更新未见对应 app_setting 审计，记录更新时间仍为 2026-09-20 |
| Android 更新设置 | 保持 0.4.7/2172；未见本任务改动 |

旧 manifest 原字节服务器备份为 `/opt/starchat/frontend/downloads/ios/manifest.plist.bak-20260924-2152`，SHA256 `a7b89bf847cdfe413c9ad2cb50eab3ffa897d5c363e472aa92cab5c2bfc4de6f`。审计前的旧 `download.html`、`admin-home.js`、manifest 原字节另存于 `docs/verification/artifacts/2026-09-24/ios-047-enterprise-distribution/preprod/`。这些仅为对照资料，不能跳过新的现值与审计核对而直接回写。

审计前 iOS 设置精确快照为：版本 `0.3.102`、构建 `2144`、安装页 `https://www.liuhetong888.com/download?platform=ios&install=1`、最低支持构建号 `3`，说明为“修复弱网发送与自动重发、拉黑与取消拉黑立即生效、通话不再虚增未读、草稿会话置顶并即时显示、转账对方收款后自动刷新、注册前可修改邮箱，红包单个上限调整为 200 点钻。”。旧下载页 4,002 字节，SHA256 `983f429d4a17d66a5a78d8dee81e1780d97e6b31ec7e3e2a2940c28b24302dc7`。

## 下一步门禁

1. 收到用户明确确认另一发布流程已暂停；重新读取静态文件 SHA、iOS/Android 设置与设置审计，再确定恢复错误部分发布的顺序，所有设置修改经 SettingService 留审计。
2. 获取与 `ZXB3TS7QD4.com.liuhetong.liuhetongMobile` 匹配的企业描述文件及完整重签 IPA，核对签名身份、版本、Team、Keychain 群组并在 iPhone 验证保留数据安装。若用户需要后台来电和聊天提醒，签名还必须具备生产 APNs 权限。
3. 仅在可用性门禁通过后，按发布计划发布不可变 IPA、manifest、下载页与更新弹窗并做前后态核验。
