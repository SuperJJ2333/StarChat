# iOS 0.3.53 客户端质量与安全复审

日期：2026-09-08。审查角色：独立于 Dart / Swift 实现者的网关实现代理。范围为隔离工作区 `docs/verification/artifacts/2026-09-08/ios-0353/source/apps/mobile_flutter/` 的 iOS Runner、iOS 通话协调器、唤醒客户端、Matrix 通话适配器、AppHome 接线与 session_store。未修改客户端实现；本记录不代替根任务对网关的独立质量审查。

结论：**最终静态质量/安全复审通过，本次检查未发现剩余客户端阻塞项。** 同意继续后续部署、构建及设备验收门禁；不代表 iOS 编译、APNs 实际送达、后台媒体或真机来电已经通过。

## 发现与修复复核

| 发现 | 最终实现复核 |
| --- | --- |
| 网关不可用时仍继续 Matrix answer，绕过首设备抢答 | `answerAndConnect` 仅接受 2xx 或明确 404（旧客户端在线来电）；503、超时及其他未确认结果拒绝媒体启动。连接前复核当前会话。 |
| 旧账号异步清理使用新凭据、旧 stop 清除新原生会话 | 唤醒客户端构造时捕获会话令牌，生成独立 registrationId；注册/注销即时加入跨实例 FIFO。原生命令及回调均携带 owner，原生拒绝旧 owner 命令，Dart 拒绝旧 owner 事件。服务端 owner/退休记录契约另由根任务独立审核。 |
| 冷启动 ready 等待 HTTP 注册及旧会话注销队列，可能超过来电有效期 | `start` 以捕获异常的 unawaited 方式注册令牌，立即调用 ready 并提取排队动作；注册不再阻塞系统接听动作。 |
| 静音覆盖尚未匹配 Matrix 的接听动作 | `_pendingMute` 与接听/结束动作分离；结束仍优先，过期动作清理，静音不替换用户接听意图。 |
| native end 仅匹配 callId；取消墓碑跨房间影响同名 callId | 原生 UUID、墓碑、匹配及 endCommand 均使用 roomId + callId；旧房间取消不能选择另一个房间的通话。 |
| 接听期间的 end 被串行队列阻塞，媒体在用户挂断后才启动 | 匹配的 end 在进入串行队列前同步设置 `_cancelRequested` 并调用 `cancelPendingAnswer`；原生 showIncoming/reportState 等待窗口结束后检查取消。适配器同时保留被取消的 CallSession 身份并递增 generation，入口身份检查覆盖权限/扬声器设置先于 backend.accept 的窗口，generation 检查覆盖已发出的 HTTP claim。 |
| 失败 claim 后重试同一通话，系统 CallKit 已结束且音频释放 | 适配器 claim/connect 异常路径拒绝仍匹配的旧 Matrix CallSession 后抛错；后续重新拨号使用新 callId，不绕过原生终态墓碑重试旧会话。 |

原生 owner 首次建立保留冷启动 PushKit 待办；已拥有 owner 的动作不能被替换 owner 重新认领。替换 owner 清理旧通话、动作和 PiP。仅完整匹配的当前 Matrix 会话和明确用户动作可触发媒体接听，普通消息不转换成 VoIP。

## 密钥与媒体边界

复核 `IOSSecureSession.swift` / bridge 与 Dart `session_store.dart`：迁移仅允许两项既有设备本地 key（Matrix 数据库密钥、business session），符合 ADR0011 的已审查范围。Keychain 查询不把 accessibility 当筛选条件；仅明确 errSecItemNotFound 表示缺失。锁定/权限错误按真实 OSStatus 向上传递，不生成替代数据库密钥，不 delete/add 修复现有记录。迁移只改 accessibility，并核对原值和 account/service/access group，未发现扩大到恢复密钥或房间密钥的路径。

原生桥仍只处理通话标识、系统控制与已在设备解密的 WebRTC 轨道；本次未发现新增密钥、SDP 或明文媒体上传路径。CallKit 音频激活和后台 PiP 的实际系统行为须由 macOS 构建与设备测试证明。

## 已查阅证据与限制

- `artifacts/2026-09-08/ios-0353/cancel-final-green.log`：最新针对性检查 **25 tests passed**，包含 backend admission 前取消保持、失败唤醒 claim 终止旧 call、旧 call 延迟 answer 不影响替换 call。
- `artifacts/2026-09-08/ios-0353/review-fixes-green.log`：前序修复针对性检查 **23 tests passed**，含冷 ready、owner、原生显示等待窗口、延迟 claim、待处理静音和 iOS 安全存储路径。
- `artifacts/2026-09-08/ios-0353/flutter-analyze.log`：已查阅的前序分析结果为 No issues found。
- `artifacts/2026-09-08/ios-0353/flutter-all.log`：已查阅的前序完整 Flutter 测试为 **1327 passed**。这些前序分析/全量结果不是最后两项适配器修改后的全量证明，最终门禁由根任务重新运行确认。
- `repository-verify.log` 在本次查看时仍有未完成输出，不据此声明仓库总验证通过。
- Windows 环境未运行 Swift/macOS 编译及物理 iOS 设备测试；未验证 TestFlight 签名候选、锁屏首次接听、后台双向音频、专注/静音模式、重启后首次解锁、真实 APNs 取消顺序或 PiP 恢复。

## 最终静态审查快照 SHA-256

以下路径均相对于隔离工作区 `apps/mobile_flutter/`：

| 文件 | SHA-256 |
| --- | --- |
| lib/features/matrix/ios_call_coordinator.dart | 6F31195E09E63B94846F47124A53304DCAB5C7A4523A6FBC037153E428AF7E8E |
| lib/features/matrix/call_wakeup_client.dart | 0602FD9C1D58F617919D9ED6669FBD4CCF66C57BB955E5F8B61C33A37B18BC0A |
| lib/features/matrix/matrix_call_adapter.dart | 8758461EF9E632B108CA1C84DFECDF4D61141B7F247E3C4C1AF99E4341FE01C7 |
| ios/Runner/IOSCallsBridge.swift | 2C18F7B914A3D302C729FAA100BC9C7408EC5AC0478F4C70900D19075BEB25D2 |
| ios/Runner/IOSCallState.swift | CBA36ABFDA8CE1B9D8D6F4D8C5A67370731F5070E82D8F57521DE2F4D6546FE3 |
