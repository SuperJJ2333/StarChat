# 六合通移动端

Flutter 客户端骨架，负责 Matrix 加密通信及彩币、红包、钱包业务入口。

## 本地开发

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

Matrix 的登录、同步和加密媒体发送通过 `MatrixE2eeClient` 封装；业务金额操作仅通过业务 API，客户端不直接修改账本。

## iOS/TestFlight 构建

iOS 构建必须在 macOS + Xcode 环境完成，Windows 不能运行 Xcode 或签名 IPA。可在 macOS runner（例如自托管 CI）执行：

```bash
flutter pub get
flutter analyze
flutter test
flutter build ipa --release --export-options-plist=ios/ExportOptions.plist
```

随后使用 App Store Connect API Key 将 `build/ios/ipa/*.ipa` 上传到 TestFlight。签名证书、`ExportOptions.plist` 和 API Key 只保存在 CI secret，不提交到仓库。首次生成 iOS 工程请在 macOS 执行 `flutter create --platforms=ios .`，并在 Xcode 中配置 bundle identifier、Team、Push Notifications 与 Associated Domains。

## 正式包标识

Android applicationId 与 iOS Bundle ID 统一为 `com.liuhetong.mobile`。

## 无 Apple 账号的 iOS 方案

没有 Apple Developer 账号时可以在 macOS 上构建 iOS Simulator 的 `.app` 用于界面和 Dart 集成测试，但不能将签名应用安装到普通 iPhone，也不能使用 TestFlight。真机测试需要 Apple ID（免费个人签名通常有有效期限制），长期分发需要 Apple Developer Program。当前 GitHub Actions TestFlight 工作流保留给正式账号环境。
