# iOS 原生 APNs 与构建修复执行细化

依据：用户本会话要求打包 iOS、启用消息推送与通话，已确认采用 GitHub macOS + TestFlight，并准备全部签名及 APNs 材料。沿用已批准产品规格及 2026-08-12-flutter-e2ee-release.md 的 Flutter/iOS 发布范围、2026-09-04-background-notification-reliability.md 的 pusher 隐私约束。

本阶段任务：原生 APNs 普通消息与 iOS 编译。文件归属：ios/Runner/AppDelegate.swift、ios/Runner/Info.plist、ios/Runner.xcodeproj/project.pbxproj、ios/Podfile、ios/Flutter/*.xcconfig、lib/features/push/native_apns_push_token_provider.dart、lib/app_home.dart、test/features/push/native_apns_push_token_provider_test.dart、独立 iOS preflight 工作流及验证文档。保留其他人的工作区修改。

1. 先在 macOS 编译当前移动端快照，保存失败日志作为构建缺陷证据。
2. Dart 测试先行：原生 start/getToken、异步 token 轮换、非法 token 拒绝、通知白名单路由、dispose 清理与异常降级。确认缺失实现失败，再实现 PushTokenProvider 的原生 MethodChannel 适配。
3. AppDelegate 使用 Flutter Swift 正确 API；原生注册 APNs、保存并转发 token、队列化冷启动通知点击；只转发 event_id/room_id 等白名单元数据，不持久化正文或密钥。通知权限沿用现有通知系统申请。
4. iOS 组合根选择原生 APNs，Android 继续原有通道。pusher app_id 与 Sygnal 保持一致；Apple topic 由真实 Bundle ID 配置。
5. 根据实际云编译错误补齐 CocoaPods、部署版本和签名配置，保持源代码可复现，测试通过后再次构建。
6. 配置与验证 Sygnal APNs 前先检查实际 schema/载荷、凭据与文件权限；不得把 FCM token 发送给 APNs。投递成功必须基于真实 iPad token 验证。
7. 本阶段验收不等同于锁屏来电完成；PushKit/CallKit、通话唤醒与音频会话需完成额外实现和真机测试。涉及 E2EE 边界变更时按项目保护规则先做 ADR 与评审，不能把全部密文消息标记为 VoIP。

补充文件归属：matrix_pusher_service.dart 及对应测试、infra/sygnal/sygnal.yaml.template、Runner 的 Debug/Release entitlements。普通 APNs 必须使用 generic default_payload 提供 alert，不能依赖 event_id_only 自动产生通知。

源码构建通过后，沿用用户授权的 GitHub macOS/TestFlight 路径：使用已验证的分发身份生成 IPA，校验生产推送 entitlement、iPad 支持和签名，保存安装包并上传 App Store Connect；不提交公开 App Store 审核。

验证：Dart 聚焦测试、格式和分析、macOS 源码编译；运行仓库聚合门禁并如实记录环境限制。证据只写 docs/verification 下。
