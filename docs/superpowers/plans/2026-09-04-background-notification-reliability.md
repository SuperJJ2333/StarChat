# 后台/锁屏/进程被杀通知可靠性修复（0.3.32）

日期：2026-09-04
状态：已批准（Plan mode 评审通过）
范围：`apps/mobile_flutter`（客户端为主）+ 根 compose/模板（Sygnal 推送网关，仅模板不部署）

## 1. 根因（已逐项验证）

1. **重复初始化**：`app_home.dart` `initState` 并发调用 `_startNotificationSystem()` 两次（197/199 行），无守卫——两套 eventSource/coordinator/deduplicator，首套泄漏整个登录会话（双声/双震/双系统通知竞争）。
2. **前台服务互踩**：`flutter_local_notifications` 19.4.2 全局仅一个 `ForegroundService`；`CallNotifications.hideOngoing()` 的 `stopForegroundService()` 会同时杀掉 `SyncKeepAliveService` 的 dataSync 保活（通话结束后消息链路死亡，仅靠 10 分钟看门狗或生命周期事件自愈）。
3. **渠道级别不足**：`chatflow_messages` 为 `Importance.defaultImportance`，无 Heads-up；Android 渠道创建后重要性/声音不可修改，老安装必须换新渠道 ID。
4. **无推送通道**：全仓库无 FCM/APNs/Sygnal/Matrix pusher 任何实现；通知完全依赖进程内存中的 onSync 长轮询，进程被杀即不可达；iOS 无 UIBackgroundModes/entitlements，keepalive 为静默空操作。
5. **吞异常**：通知启动关键路径 `catch (_) {}`（注释承诺的"生命周期恢复可重试"并不存在），权限/声音/渠道等多处静默，无法定位失败层级。
6. **去重不跨重启**：`NotificationDeduplicator` 纯内存，"系统推送已展示、App 启动后同步又提醒一次"无法防（为推送通道预留）。
7. `FriendRequestNotifier.initialize()` 抢先弹系统权限框，违反 PRD §33 上下文式申请并与登录引导双弹窗。
8. 版本线：0.3.29（+32）已含 ff5c6eb、0.3.30（+33）含三层保活，问题仍复现（工作区已有未提交的第四次修复：`matrix_sync_watchdog`）。本次发布 **0.3.31+34**（> 线上 2033）。

## 2. 变更清单

### A. Android 短期修复

| 项 | 文件 | 内容 |
|---|---|---|
| A1 单例初始化 | 新 `lib/core/notification/notification_system_bootstrapper.dart`；`lib/app_home.dart` | Future 备忘录保证一次装配；失败可由生命周期恢复重试；dispose 清理唯一实例 |
| A2 前台服务仲裁 | 新 `lib/core/notification/foreground_service_arbiter.dart`；`sync_keepalive_service.dart`、`call_notifications.dart`、`app_home.dart` | `ForegroundServiceArbiter`（owner 状态机：ongoingCall > keepAlive）；release 后重申剩余最高优先级请求而非 stop；共享一个 arbiter 实例 |
| A3 渠道 v2 | `system_notification_presenter.dart` | 新渠道 `chatflow_messages_v2`（IMPORTANCE_HIGH+声音+渠道级震动+category message）；messages 枚举映射 v2；旧渠道标 legacy 不创建不删除；`chatflow_silent` 保持 low |
| A4 渠道深链 | `MainActivity.kt`、设置页 | `openChannelSettings(channelId)` + `getChannelState(channelId)` 原生方法；设置页"通知渠道设置"入口 |
| A5 权限生命周期 | `app_home.dart`、`notification_settings_page.dart`、`friend_request_watch.dart` | 回前台重查权限并记诊断；设置页 resume 刷新（从系统设置返回后重查）；移除 FriendRequestNotifier 抢先申请 |
| A6 诊断日志 | 新 `notification_diagnostics.dart` + 各埋点 | 阶段化（startup/sync_arrived/policy/suppressed/system_show/permission/channel/fgs/push），id 截断脱敏，SharedPreferences 环形缓冲（120 条），设置页可查看复制 |
| A7 持久去重 | `notification_deduplicator.dart`、`notification_coordinator.dart`、`app_home.dart` | `NotificationDedupStore` 抽象（内存 + SharedPreferences，TTL 24h）；推送点击复用同一 store |
| A8 文档措辞 | `docs/NOTIFICATION_SYSTEM.md` | 明确 dataSync FGS 受 Android 14+ 每日 ~6h 配额限制，非永久方案 |

### B. 推送长期方案（完成所有不依赖凭据的部分）

| 项 | 文件 | 内容 |
|---|---|---|
| B1 服务端模板 | `docker-compose.yml`、`docker-compose.production.yml`（注释块）、`data/sygnal/sygnal.yaml.example`、homeserver 模板、`.env.example` | Sygnal 服务（显式版本镜像、无凭据可启动）；`push.include_content: false` 显式化；不部署 |
| B2 客户端 | 新 `lib/features/push/`（token provider、matrix pusher 注册/注销、tap 路由、firebase 接线）；pubspec、android gradle（条件 google-services）、ios Info.plist（remote-notification bg mode）、entitlements 模板 | Matrix pusher（kind=http、format=event_id_only、`LIUHETONG_SYGNAL_URL` dart-define）；登录注册/token 刷新重注册/登出注销；冷启动 payload → 持久去重 → 首同步后进入会话；无凭据时 Noop 安全降级；后台消息只显通用文案 |
| B3 凭据清单 | `docs/PUSH_SETUP.md` | google-services.json/FCM 密钥、APNs 证书与 Team ID、生产网关域名与部署授权；人工步骤；不硬编码不伪造 |

## 3. E2EE 与合规边界

- 推送载荷仅 eventId/roomId/类型/通用文案；`format: event_id_only`；服务端 `include_content: false`；测试断言载荷不含正文字段。
- 不删用户渠道、不覆盖用户渠道选择；渠道升级走新 ID + 设置页入口。
- 持久化去重键为 eventId（本地 opaque 标识），不含消息内容。
- 诊断日志不含消息正文、Token、密钥、完整房间/事件 ID（仅前缀截断）。

## 4. 测试计划（先行红后实现绿）

新增/扩展：bootstrapper 单例与重试、arbiter 所有权与"通话结束不停止消息链路"集成、渠道 v2 规格/映射/legacy 保留、权限重查、持久去重跨实例、诊断脱敏与容量、pusher 注册/刷新/注销/无网关不注册/载荷 E2EE 断言、push tap 冷启动路由。

全量：`flutter analyze`（0 issues）→ `flutter test` → `scripts/verify.ps1`（仓库聚合门禁）。

## 5. 发布（不部署、不发布）

- 版本 `0.3.31+34`（工作区已递增，未发布过；> 线上 0.3.30/2033）。
- `scripts/build_mobile_public_domain.ps1` 构建 standard flavor APK；aapt 版本守卫 + SHA256 记录至 `docs/verification/2026-09-04-background-notifications.md`（含根因报告、变更清单、测试证据、发布/回滚检查表、待人工项）。
- 本地 git 提交；不 push、不执行容器发布脚本。
