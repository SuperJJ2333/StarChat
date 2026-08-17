# 畅聊桌面图标铺满修复验证

日期：2026-08-17  
设备：雷电模拟器 `emulator-5554`  
应用 ID：`com.liuhetong.mobile`

## 根因

- `assets/branding/app_icon.png` 的画布为 `1024×1024`，但有效 Logo 像素仅位于左上角 `552×574`。
- `flutter_launcher_icons` 按错误母版生成全部密度资源，Android 自适应图标又施加 `16%` 前景内缩，导致桌面图标只占左上区域。

## 修复

- 从 `assets/branding/liuhetong_logo.svg` 内嵌的官方 Logo 等比居中裁切并生成 `1024×1024` 方形母版，未拉伸图形。
- 设置 `adaptive_icon_foreground_inset: 0`，消除第二次缩小。
- 使用 `flutter_launcher_icons 0.14.4` 重新生成 Android 与 iOS 全套图标资源。
- 新增 `test/ui/launcher_icon_asset_test.dart`，锁定方形画布、四边覆盖和 Android 零内缩合同。

## Red / Green 证据

- Red：母版有效像素边界为 `(0, 0, 552, 574)`，期望右边界 `1023`、实际 `551`；自适应 XML 实际为 `16%` 内缩，2 项测试失败。
- Green：母版有效像素边界为 `(0, 0, 1024, 1024)`；Android 前景各密度和 legacy mipmap 的有效像素边界均覆盖完整画布；2 项聚焦测试通过。

## 自动验证

- `dart format --output=none --set-exit-if-changed test/ui/launcher_icon_asset_test.dart`：PASS。
- `flutter analyze`：PASS，0 issues。
- `flutter test`：PASS，105 tests。
- `flutter build apk --debug --target-platform android-x64`：PASS。
- `pwsh -NoProfile -File scripts/verify.ps1`：PASS；Business API/Worker `161 passed, 1 skipped`，Matrix Bot `9 passed`，Flutter boundary `19 passed`。

## 模拟器验证

- 先卸载旧包以清除 Launcher 图标缓存，再安装新 APK：两步均返回 `Success`。
- 启动 `com.liuhetong.mobile/.MainActivity` 成功，返回桌面后确认 Logo 居中并覆盖完整图标区域。
- 截图：`docs/verification/screenshots/2026-08-17-launcher-icon-fixed.png`。
