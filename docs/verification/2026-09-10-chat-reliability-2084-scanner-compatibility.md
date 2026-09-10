# iOS 扫码与推送原生依赖兼容

## 现象与根因

完整 iOS native CI job 102830412689 解析依赖失败：mobile_scanner 5.2.3 的 MLKit 6 链要求 GoogleDataTransport <10，而 Firebase 12.18 要求 ~10.1。Dart 测试不能发现 CocoaPods 约束冲突。

## 修改

精确升级 mobile_scanner 到 6.0.11，保留扫码、照片识码及 Firebase 推送。flutter pub get 仅变更此一个依赖；没有 dependency override、native patch 或功能删除。

官方来源确认：
- [6.0.11 podspec](https://raw.githubusercontent.com/juliansteenbakker/mobile_scanner/v6.0.11/ios/mobile_scanner.podspec) 依赖 GoogleMLKit/BarcodeScanning ~7.0.0，最低 iOS 15.5。
- [GoogleMLKit 7.0.0](https://raw.githubusercontent.com/CocoaPods/Specs/master/Specs/b/e/b/GoogleMLKit/7.0.0/GoogleMLKit.podspec.json) 依赖 MLKitCommon ~12.0.0。
- [MLKitCommon 12.0.0](https://raw.githubusercontent.com/CocoaPods/Specs/master/Specs/c/c/6/MLKitCommon/12.0.0/MLKitCommon.podspec.json) 依赖 GoogleDataTransport ~10.0、GoogleUtilities ~8.0，与 Firebase 所需版本存在交集。

项目 iOS deployment target 已为 16.0，无需提升。业务 scan_qr_page.dart 调用兼容；仅测试 fake 的 analyzeImage 补可选 formats 参数。模拟器诊断的 scanner 排除版本断言同步为 6.0.11；MLKit 仍缺 ARM64 simulator slice，诊断排除不能代替完整生产插件编译。

## 验收与边界

- 升级后测试 API 编译失败有 scanner-api-red.log；适配后 7 个扫码相关测试文件合计 29 tests passed。
- scanner-analyze.log：业务扫码页及测试分析无问题。
- 证据位于 docs/verification/artifacts/2026-09-10/chat-reliability-2084/video/scanner-*.log。
- 6.0.11 Android 原生依赖使用 CameraX 1.5.0、compileSdk 36、Java 17、Kotlin 2.2.20，需本轮 Android 重建覆盖。
- Windows 未运行 CocoaPods/Xcode；完整 iOS native CI 必须在主任务推送后跑绿，才能确认全部原生依赖与 Swift 编译通过。本报告不声称已完成 iOS 编译。
