# 2026-08-12 Flutter 客户端与 Matrix E2EE 验证

## 环境

- Flutter 3.44.9 stable / Dart 3.12.2
- Android SDK + NDK 28.2.13676358
- Android debug APK: `apps/mobile_flutter/build/app/outputs/flutter-apk/app-debug.apk`

## 通过项

- `flutter analyze`：通过
- `flutter test`：通过（1 个 widget 测试）
- `flutter build apk --debug --no-pub`：通过
- `scripts/verify.ps1`：通过（业务 API/Worker 71 passed, 1 skipped；Flutter boundary 2 passed）
- Matrix 客户端封装了登录、同步、设备密钥验证、SSSS 加密备份、加密文本与媒体事件发送。
- 客户端页面已建立彩币、红包、USDT-TRC20 钱包入口，金额操作通过业务 API 边界。

## 未完成/外部依赖

当前主机为 Windows，无法运行 Xcode、iOS 模拟器或 Apple 签名工具，因此未在本机生成 IPA/TestFlight 包。iOS 工程生成、签名和上传必须转移到 macOS CI，并使用受保护的 Apple Team、证书、Provisioning Profile 与 App Store Connect API Key。执行步骤见 `apps/mobile_flutter/README.md`。
