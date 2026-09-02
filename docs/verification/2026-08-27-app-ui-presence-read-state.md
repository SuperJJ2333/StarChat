# ChatFlow APP UI 与在线埋点修复验证（2026-08-27）

## 变更
- 自定义头像继续使用业务 API 签名 URL、统一 AvatarCache；首帧解码前保持稳定 fallback，失败回退最近成功图像。
- 进入会话立即写入本地 ConversationReadState，并在 RoomPage timeline `markRead`；返回列表不会因旧 Matrix notificationCount 重新显示红点，新入站事件仍恢复未读。
- 会话导航使用 `_openingRoom` 互斥及 `try/finally`，快速重复点击只 push 一次且异常时锁必然释放。
- 登录成功保存 device_key；每 60 秒 `POST /api/v1/presence/heartbeat` 携带 Bearer 与 `X-Device-Key`，仅更新设备 `last_seen_at`。
- 管理后台在线口径：ACTIVE 用户的未撤销设备，最近 5 分钟，按 user 去重。

## RED/GREEN 与命令证据
| 阶段 | 命令 | 结果 |
|---|---|---|
| RED | `flutter test ... conversation_read_state_test.dart`（实现前） | FAIL：文件/类型不存在 |
| RED | `flutter test ... business_api_presence_test.dart`（实现前） | FAIL：未登录仍发送请求 |
| GREEN | `flutter test test/core/business_api_presence_test.dart test/core/business_api_session_test.dart` | 11/11 passed，exit 0 |
| GREEN | `flutter test test/core/business_api_presence_test.dart test/features/matrix/conversation_read_state_test.dart test/features/matrix/avatar_url_resolver_test.dart test/ui/wechat_components_test.dart` | 28/28 passed，exit 0 |
| 静态检查 | `flutter analyze` | No issues found，exit 0 |
| 格式化 | `dart format ...` | 完成，exit 0 |
| API 回归 | `pytest tests/business_api/admin/test_admin_api.py -q` | 3 passed，exit 0 |
| 生产健康 | `GET https://liuhetong888.com/api/v1/health/live` | HTTP 200，`{"ok":true,"service":"畅聊 Business API"}` |
| 未认证边界 | `POST https://www.liuhetong888.com/api/v1/presence/heartbeat` | HTTP 404（www 静态首页路由不暴露 API）；API 正式入口为 `https://liuhetong888.com` |
| 生产容器 | `docker compose ... ps` | business-api/business-postgres/business-redis/synapse/element-web healthy/running |

## 运行时说明
在线人数不会由 Matrix sync 单独推断；APP 需完成业务登录并保持前台，首次进入消息页立即心跳，之后每 60 秒一次。服务端查询窗口 5 分钟，因此停止心跳约 5 分钟后自动离线。心跳不包含 Matrix 消息、密钥、正文或附件。

## 回滚
仅回滚 APP 代码即可停止心跳与本地读状态桥；Business API 接口为新增兼容端点，不要求数据库迁移。头像与 Matrix 聊天接口未改变。若需回滚服务端，恢复之前 business-api 镜像并保持现有设备 `last_seen_at` 字段，聊天 API 不受影响。

## APK 构建与设备验证
- 构建：`flutter build apk --release --dart-define=LIUHETONG_BUSINESS_API_URL=https://liuhetong888.com --dart-define=LIUHETONG_MATRIX_HOMESERVER=https://liuhetong888.com`，exit 0；APK `apps/mobile_flutter/build/app/outputs/flutter-apk/app-release.apk`，SHA-256 `D2969479F46E13F9B20D2243D0A6945B7F3C46CA51035450A170D45E71CA3BCA`。
- `emulator-5554` 已连接；`adb install -r` 返回 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`，设备保留既有不同签名的安装以保护其 Matrix 本地加密数据库和安全存储。未卸载/清数据。
- 设备当前前台 Activity：`com.liuhetong.mobile/.MainActivity`；未发现本次操作产生的 `FATAL EXCEPTION` 或 `E/flutter` 行。
