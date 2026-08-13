# 六合通 Cupertino UI 验证

- `flutter analyze`: 通过（No issues found）。
- `flutter test`: 通过（2 tests passed）。
- `flutter build apk --debug --no-pub`: 通过，生成 `apps/mobile_flutter/build/app/outputs/flutter-apk/app-debug.apk`。
- Android 模拟器 `emulator-5554`、`emulator-5556`：安装并启动 `com.liuhetong.mobile` 成功。
- UIAutomator 检查：登录导航标题、六合通品牌文案、用户名/密码输入框和登录按钮均可见。
- 设计覆盖：CupertinoApp、CupertinoTabScaffold、CupertinoFormSection、品牌启动图矢量资源；业务 API、Matrix E2EE 与钱包边界未改变。
