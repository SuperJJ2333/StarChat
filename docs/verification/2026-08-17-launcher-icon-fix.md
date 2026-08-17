# 畅聊桌面图标铺满修复验证

日期：2026-08-17  
设备：雷电模拟器 `emulator-5554`  
应用 ID：`com.liuhetong.mobile`

## 最终根因

- `assets/branding/app_icon.png` 的画布为 `1024×1024`，但有效 Logo 像素仅位于左上角 `552×574`。
- 第一次修复正确解决了左上角错位，但随后把 Android 自适应前景内缩从默认值改为 `0%`，导致新母版在 Launcher 的自适应图标坐标系中被再次放大并被蒙版裁切。
- 新母版的可见像素在 `1024×1024` 上接近 100% 覆盖；它不是“只有中心 Logo 的透明前景”，而是一张已包含绿色圆角底板的完整图标。仅使用 alpha 边界只能判断是否偏移，不能判断 Android Launcher 最终呈现的视觉安全区。
- Android 自适应图标前景使用 108dp 坐标系，并由 Launcher 按圆形、圆角方形等蒙版裁切；源图尺寸、前景 inset、系统蒙版和启动器缓存共同决定最终视觉大小。因此 `0%` 虽然在文件层面“铺满”，在桌面上却表现为过大。

## 修复

- 从 `assets/branding/liuhetong_logo.svg` 内嵌的官方 Logo 等比居中裁切并生成 `1024×1024` 方形母版，未拉伸图形。
- 依据母版接近 100% 的实际覆盖率，将 `adaptive_icon_foreground_inset` 设置为 `17`：左右/上下各内缩 17%，保留约 `66%` 的中心尺寸，即按需求缩小约三分之一，并接近 Android 自适应图标安全区。
- 使用 `flutter_launcher_icons 0.14.4` 重新生成 Android 与 iOS 全套图标资源。
- 更新 `test/ui/launcher_icon_asset_test.dart`，锁定方形母版及 Android `17%` 内缩合同，避免再次在“铺满”和“过小”之间反复。

## Red / Green 证据

- Red：母版有效像素边界为 `(0, 0, 552, 574)`，期望右边界 `1023`、实际 `551`；自适应 XML 实际为 `16%` 内缩，2 项测试失败。
- 第二轮 Red：测试期望 `17%`，实际 XML 仍为 `0%`，按预期失败。
- 最终 Green：母版保持 `(0, 0, 1024, 1024)`；Android 自适应 XML 为 `17%`，2 项聚焦测试通过。

## 自动验证

- `dart format --output=none --set-exit-if-changed test/ui/launcher_icon_asset_test.dart`：PASS。
- `flutter analyze`：PASS，0 issues。
- `flutter test`：PASS，116 tests。
- `flutter build apk --debug --target-platform android-x64`：PASS。
- `pwsh -NoProfile -File scripts/verify.ps1`：PASS；Business API/Worker `161 passed, 1 skipped`，Matrix Bot `9 passed`，Flutter boundary `19 passed`。

## 模拟器验证

- 使用 `adb install -r` 覆盖安装到雷电模拟器，返回 `Success`，登录态未清除。
- 返回 `com.android.launcher3/.Launcher` 后确认外部图标槽尺寸与其他应用一致，内部 Logo 居中、完整、不再顶边或被蒙版裁切。
- 最终截图：`docs/verification/screenshots/2026-08-17-launcher-icon-inset17.png`；局部截图：`docs/verification/screenshots/2026-08-17-launcher-icon-inset17-crop.png`。
