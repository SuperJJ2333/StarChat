# iOS / iPad 安装交付检查

日期：2026-09-07。状态：未生成 IPA，未执行 Xcode 编译、签名、TestFlight 上传或 iPad 实测。

用户后续确认：仅有 Windows 和 iPad；用户报告系统版本 26.6.1，尚未真机核实；Apple Team ID 为 HY9Q7Q35S5；尚未注册 App ID 或创建 App Store Connect 应用。继续沿用现有 Bundle ID com.liuhetong.liuhetongMobile 准备注册，Apple 端可用性尚未核实。

云构建检查：GitHub 连接已成功读取 SuperJJ2333/StarChat 仓库元数据并返回管理及推送权限。未检查 Actions secrets、未触发工作流。优先采用已有 GitHub Actions macOS 路线；具体浏览器操作见 docs/runbooks/ios-windows-testflight-setup.md。

后续进度：用户已回复“应用已创建”。此为用户确认，尚未通过 Apple 控制台/API 验证；下一步配置 App Store Connect 上传密钥，以及分发证书/描述文件。未生成 IPA。

## 已核实

- 当前工作环境为 Windows，未发现 xcodebuild；Flutter 位于 C:/src/flutter/bin/flutter.bat。尚未获得可访问的 macOS 构建机或 Apple Team ID。
- 已有 ios/Runner.xcworkspace 和 .github/workflows/ios-testflight.yml，不能据此认定工作流可成功发布。
- Runner 工程支持设备族 1,2（iPhone/iPad），当前工程部署目标为 13.0；实际最低系统版本仍须结合插件依赖在 Xcode 解析、构建验证。
- Info.plist 已声明相机、麦克风、相册读取用途和 remote-notification 后台模式；尚未声明 audio 后台模式。
- Runner.Push.entitlements.template 明确说明模板不直接生效；project.pbxproj 未找到 CODE_SIGN_ENTITLEMENTS 或 DEVELOPMENT_TEAM 设置。
- ios 目录未发现 GoogleService-Info.plist 或 Podfile。依赖集成方式和 Firebase 配置需要在 macOS 构建时落实，不能假定安装依赖已经完成。
- AppDelegate.swift 的角标桥使用 MethodChannel、直接下标访问 call.arguments，需改为符合 Flutter Swift API 的 FlutterMethodChannel 和安全参数转换，并由 Swift 编译验证。
- firebase_push_wiring.dart 明确把 iOS PushKit + CallKit 列为独立后续工作。现有普通通知链路不能作为锁屏来电可用的证明。
- docs/PUSH_SETUP.md 记载 Sygnal 的 FCM/APNs 凭据未激活；本次未连接生产验证，不能把该历史状态当作当前远端检查结果。
- 当前工作区存在其他业务改动，本次未修改应用源码或触发远端发布。

## 完成交付所需工作

1. 确定可访问的 Mac 或 macOS CI、Team ID、最终 Bundle ID 和测试 iPadOS 版本。签名私钥、账户密码不通过聊天或仓库传递。
2. 在 Apple Developer 注册对应 App ID，启用 Push Notifications，配置签名证书和匹配的描述文件；在 App Store Connect 创建同 Bundle ID 的应用。
3. 修复 Swift 编译问题，落实插件依赖、实际部署目标、entitlements 和权限请求；用 macOS 执行依赖解析、分析、测试和真机 archive。
4. 接通普通消息的 APNs 投递链路；若沿用 Firebase，配置 iOS Firebase 应用、客户端配置和服务端 APNs 凭据，验证 APNs token 到 FCM token 到 Matrix pusher 的完整注册与注销。
5. 补齐 PushKit/CallKit、音频会话和后台音频处理。VoIP 推送仅用于真实来电，不得把全部加密消息伪装为来电。当前 event_id_only 网关无法可靠识别加密来电，需要单独设计兼容 E2EE 边界的来电唤醒流程，并遵守项目相关设计与评审要求。
6. 用真实 iPad 验证前台、后台、锁屏消息提醒，来电接听/拒接/取消/超时，语音视频双向媒体，权限拒绝后恢复，登出换号、断网重连和重复推送。普通静默通知不提供即时唤醒保证。
7. 生成并验证签名 IPA 后上传 TestFlight；记录构建号、SHA-256、签名 Team/Bundle、描述文件、最终 entitlements 和真机结果。

## iPad 安装：优先使用 TestFlight

个人付费 Apple Developer 账号可使用 TestFlight，符合项目既有分发方案。

1. 完成上述配置并在 Mac/Xcode 或 macOS CI 生成、上传构建。Flutter 的 flutter build ipa 输出 archive 和 IPA，但本项目当前尚不满足成功构建前置条件。
2. App Store Connect 中等待构建处理完成，按实际加密使用情况填写出口合规信息；不要为了跳过问题随意声明不使用加密。
3. 在应用的 TestFlight 页面建立内部测试组，把有权限的自己的 App Store Connect 账号加入，给测试组分配构建。外部测试按 Apple 测试审核流程办理。
4. 在 iPad 的 App Store 安装 TestFlight，接受测试邀请，在 TestFlight 中点安装。此路线不需要提供 iPad UDID，也不需要开启开发者模式。
5. 首次使用时允许通知、麦克风和相机。在 iPad 设置的通知页面开启该应用的允许通知、锁定屏幕、通知中心、横幅、声音；测试时检查专注模式和通知摘要设置。
6. 这些系统开关不能替代应用内的 APNs、PushKit、CallKit 实现，必须通过真机收发和来电测试确认。

如需开发时 USB 直装：在 Mac 的 Xcode 登录开发者账号，连接并信任 iPad，按系统提示启用开发者模式，设置 Runner 的签名 Team，选择 iPad 后运行。Ad Hoc 则需要登记设备 UDID 并生成包含该设备的描述文件。App Store/TestFlight 类型 IPA 不能作为通用安装文件直接在 iPad 点击安装。

## 官方参考

- Flutter iOS 构建：https://docs.flutter.dev/deployment/ios
- Flutter iOS 环境：https://docs.flutter.dev/platform-integration/ios/setup
- TestFlight 内部测试：https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers
- Apple 测试分发：https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases
- PushKit 来电处理：https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit
- Firebase Flutter 推送：https://firebase.google.com/docs/cloud-messaging/flutter/get-started
