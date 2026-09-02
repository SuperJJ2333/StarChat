# 2026-08-28 模拟器“网络未连接”排查

## 根因
模拟器 Wi‑Fi 已连接并通过 DNS 解析 `liuhetong888.com`。但 APP release 默认配置仍指向 `http://127.0.0.1:8082` 和 `http://127.0.0.1:8008`；在 Android 模拟器中 127.0.0.1 是模拟器自身，不是生产服务器，因此登录请求无法到达 Business API，界面显示“网络未连接”。

## 修复
`apps/mobile_flutter/lib/core/app_config.dart` 默认值已改为：
- Business API：`https://liuhetong888.com`
- Matrix homeserver：`https://liuhetong888.com`
仍可通过 `--dart-define=LIUHETONG_BUSINESS_API_URL=...` 与 `LIUHETONG_MATRIX_HOMESERVER=...` 覆盖测试环境。

## 验证
- 模拟器网络：WIFI `CONNECTED/CONNECTED`，`VALIDATED=true`，DNS 可用。
- 模拟器 DNS：`liuhetong888.com -> 207.56.8.8`，ICMP 0% 丢包。
- 模拟器 HTTPS：`https://liuhetong888.com/api/v1/health/live` 可建立连接（HEAD 返回 405，服务仅允许 GET，证明已到达 API）。
- 配置回归测试：`flutter test test/core/app_config_test.dart` -> 1 passed。
- 静态分析：`flutter analyze lib/core/app_config.dart` -> No issues found。
- Release 构建：成功；APK SHA-256 `EE93907D33FAF205EE83193BBC213D8CC4D9970BC075295A5BF3F4107F0AA1E9`。
- `emulator-5554` 安装 release APK：`Success`，`MainActivity` 前台。
