# ChatFlow 统一通知与音频反馈系统

**适用客户端：** `apps/mobile_flutter`（畅聊 ChatFlow）
**实现日期：** 2026-09-03
**依据：** 《ChatFlow 通知与音频反馈系统 PRD V1.0》§1–§70
**实施计划：** `docs/superpowers/plans/2026-09-03-notification-audio-feedback-system.md`
**验收矩阵：** `docs/NOTIFICATION_QA_MATRIX.md`

---

## 1. 架构总览

```text
Matrix Sync (sdkClient.onSync)
        ↓
MatrixNotificationEventSource            ← 事件事实：自己消息/当前会话/静音/特别关注/@我
        ↓ IncomingNotification
NotificationCoordinator（唯一入口）
        ├─ NotificationDeduplicator       ← eventId TTL 10min 去重（PRD §25/§66）
        ├─ NotificationPolicyEngine       ← 纯函数决策（PRD §22）
        ├─ SoundCooldownGate              ← 同会话 2s / 全局 600ms（PRD §41）
        ↓ NotificationDecision
        ├─ InAppBannerController + InAppBannerOverlay   ← 前台横幅（PRD §7）
        ├─ ForegroundSoundService (audioplayers)        ← 前台音效
        ├─ HapticService                                 ← 震动（PRD §37）
        ├─ FlutterLocalSystemNotificationPresenter       ← 后台系统通知（PRD §19）
        └─ BadgeService (flutter_app_badger)             ← 桌面角标（PRD §35/§36）
```

- 所有代码位于 `apps/mobile_flutter/lib/core/notification/`；Matrix 适配层在
  `lib/features/matrix/matrix_notification_event_source.dart`。
- **业务页面禁止直接 `AudioPlayer().play(...)` 或创建系统通知**（PRD §2/§68-2/3）。
  纯前台 UI 反馈（发送成功/红包开启/扫码）经 `NotificationFeedback.shared.play(...)`
  间接进入协调器（检查声音开关后播放）。
- 组合根：`lib/app_home.dart` 的 `_AppHomeState._startNotificationSystem()`。

## 2. 通知优先级与决策表（PRD §3/§22）

| 条件（按序短路） | 结果 |
| --- | --- |
| 自己发送的消息 | 无通知、无声、无震动、无未读、无角标（PRD §26/§52） |
| 当前正在查看的会话 | 同上（已读回执由聊天页推进，PRD §18/§53） |
| 消息通知总开关关闭 | 仅保留角标刷新 |
| 会话静音（无例外） | P4 静默：无横幅/声音/震动；后台静默渠道保留通知中心；未读计数保留（PRD §29） |
| 静音 + @我/关注例外 | P1：mention 音效 + 双轻震 + mentions 渠道 |
| 特别关注（会话三态） | P1：attention 音效 + 双轻震 + attention 渠道（PRD §27） |
| 群聊 @我 | P1：mention 音效 + 双轻震 + mentions 渠道（PRD §28） |
| 勿扰窗口内（普通/@我） | 静默（PRD §30）；特别关注仅在"勿扰期间允许特别关注"开启时提醒 |
| 通话中（普通消息） | 无横幅/声音/震动，仅角标；特别关注允许极轻提示音（PRD §40） |
| 普通消息 | P2：message_received 音效 + 轻震；前台横幅 / 后台系统通知 |
| 业务通知（P3） | notification 音效 + system 渠道 |

- 前台不出系统通知；后台由系统渠道发声，**Flutter 绝不在后台播放声音**
  （PRD §19 防"叮叮两次"）。
- 隐私三档（PRD §20/§45）：`showAll`（姓名+内容）/ `nameOnly`（姓名+「你收到了一条新消息」）
  / `hideAll`（「畅聊 / 新消息」），横幅与系统通知正文统一裁剪。

## 3. Android 通知渠道（PRD §31）

| Channel ID | 用途 | Importance | 声音（res/raw） |
| --- | --- | --- | --- |
| `chatflow_messages` | 普通消息 | DEFAULT | chatflow_message.ogg |
| `chatflow_mentions` | @我 | HIGH | chatflow_mention.ogg |
| `chatflow_attention` | 特别关注 | HIGH | chatflow_attention.ogg |
| `chatflow_system` | 系统业务通知 | DEFAULT | chatflow_system.ogg |
| `chatflow_silent` | 静默同步 | LOW | 无声 |

既有渠道行为不变：`calls` / `call-ongoing`（来电全屏意图与前台服务）、
`changliao_message_reminders`（定时提醒）、`changliao_friend_requests`（好友申请）。
同会话系统通知聚合：`notificationId = sha256(roomId) 前 4 字节`（PRD §16/§42）。

## 4. 权限（PRD §33/§34/§56）

- 登录后首次进入主界面弹说明框 → 再触发系统 `POST_NOTIFICATIONS` 申请；
  冷启动首屏绝不弹权限框。
- 原先散落在 `FlutterLocalNotificationScheduler` / `CallNotifications` 初始化里的
  自动权限申请已移除（统一入口）；定时提醒必需的精确闹钟权限保留原位。
- 权限被拒后：设置 → 通知与声音 顶部显示「系统通知已关闭」警告卡；
  iOS 提供 `app-settings:` 跳转（url_launcher），Android 本期显示引导文案。
- 系统 DND、通知权限、渠道设置永远以操作系统为最终决策（PRD §62）。

## 5. 音效资产

### 5.1 生成管线

- 母带：`apps/mobile_flutter/assets/SE/`（用户提供的 7 个 MP3，**不改动**）。
- 生成：`scripts/build_notification_sounds.ps1`（ffmpeg）产出
  `apps/mobile_flutter/assets/sounds/`（15 个规范化 MP3）与
  `android/app/src/main/res/raw/*.ogg`。
- `message_received` 已裁掉母带头部 0.805s 静音与尾部静音（PRD §5 快速起音要求；
  实测有效音长约 0.70s）。
- pubspec 已注册 `assets/sounds/`。

### 5.2 SoundType → 文件映射与顶替清单

| SoundType | 文件 | 实测时长 | 来源 / 顶替说明 |
| --- | --- | --- | --- |
| messageReceived | message_received.mp3 | 0.70s | 母带 message_reminder_se 裁静音 |
| messageSent | message_sent.mp3 | 0.31s | 母带 voice_message sending_se 裁静音 |
| messageAttention | message_attention.mp3 | 0.70s | **顶替**＝message_received |
| mention | mention.mp3 | 0.70s | **顶替**＝message_received |
| notification | notification.mp3 | 0.70s | **顶替**＝message_received |
| callVoiceIncoming | call_voice_incoming.mp3 | 6.28s | **顶替**＝视频铃声 |
| callVideoIncoming | call_video_incoming.mp3 | 6.28s | 母带 video_call _ringtone_se |
| callOutgoing | call_outgoing.mp3 | 1.06s | 母带 video_call _waiting _se |
| callConnected | call_connected.mp3 | 0.35s | **顶替**＝等待音截短+淡出 |
| callEnded | call_ended.mp3 | 0.84s | 母带 video_call _hang-up_se |
| diamondReceived | diamond_received.mp3 | 2.40s | **顶替**＝红包开启音 |
| transferReceived | transfer_received.mp3 | 2.40s | **顶替**＝红包开启音 |
| redpacketReceived | redpacket_received.mp3 | 2.40s | **顶替**＝红包开启音 |
| redpacketOpen | redpacket_open.mp3 | 2.40s | 母带 red_packet_opening_se |
| scan | scan.mp3 | 0.42s | 母带 scan_se |

**正式素材替换方法：** 将新的 MP3 覆盖 `assets/SE/` 对应母带并重跑
`pwsh -NoProfile -File scripts/build_notification_sounds.ps1`，或直接覆盖
`assets/sounds/<SoundType 文件名>`——代码与 SoundType 映射不变。
单测 `sound_type_assets_test.dart` 保证每个枚举值都有非空资产文件。

### 5.3 音频上下文（PRD §39）

- Android：`usageType=notificationCommunicationInstant`、不抢占音频焦点；
  iOS：`ambient`（尊重静音键、与其他应用混音）。不修改系统音量。

## 6. 通话音效（PRD §5/§9/§10）

- 被叫铃声：语音/视频各自循环铃声（`SoundServiceCallAlertDriver`，1.8s 节拍维持
  震动并确保铃声存活）；主叫使用呼叫等待音循环。
- 接通播放 `call_connected`，结束播放 `call_ended`（`CallSoundCues`）。
- 铃声受"语音/视频通话通知"设置开关约束；通话期间普通消息默认静默（§2 决策表）。
- 来电系统通知沿用既有 full-screen-intent 方案（`calls` 渠道），本期未改为
  Notification.CallStyle（后续阶段，见 §8）。

## 7. 设置项（PRD §43/§44/§67）

- 全局：设置 → 消息通知（通知与声音）页。开关：消息通知、显示消息详情（三档）、
  声音、震动、桌面角标、特别关注提醒、@我提醒、语音/视频通话通知、勿扰模式
  （起止时间 + 勿扰期间允许特别关注）、静音会话计入桌面角标。
- 会话级：群聊/私聊信息页 → 消息通知三态（默认 / 静音 / 特别关注，PRD §44 第一版），
  静音态保留既有"@我/@所有人/群公告仍通知"与"折叠该聊天"。
- 持久化：全局 `SharedPreferences`（`notification.*` 键）；会话级 Matrix 房间
  account-data `com.liuhetong.conversation.settings.v2` 新增 `attention` 字段
  （默认 false，向后兼容；与 muted 互斥）。

## 8. 后台/锁屏保活（2026-09-03 BUG 修复）

后台/锁屏收不到通知的根因：Android 后台进程数分钟内被冻结/查杀，Matrix
同步长连接随之中断——消息通知、来电铃声全部无法触达（通知管线本身完整：
策略引擎后台发系统通知、渠道带声、来电走 full-screen intent + 应用内铃声
循环）。修复（`lib/core/notification/sync_keepalive_service.dart`）：

- 登录会话期间常驻 **dataSync 类型前台服务**（`chatflow_sync` 渠道低优先级
  无声常驻通知"畅聊消息服务运行中"，通知 id 41003），维持同步长连接存活：
  消息通知（渠道声+震动）、来电铃声（应用内循环）与全屏来电在后台/锁屏
  正常触发。AppHome initState 启动、dispose（退出登录）停止、回前台幂等
  补启（应对系统配额回收）。
- Manifest：`FOREGROUND_SERVICE_DATA_SYNC` 权限 + ForegroundService 声明
  `dataSync|microphone|camera`。
- 消息通知锁屏可见性设为 `public`（内容已按 previewPrivacy 分级裁剪）。
- Mi 6（Android 9）真机验证：息屏状态下注入对方消息，锁屏显示"畅聊·这个
  小鸿：后台锁屏通知验证消息"，渠道 `chatflow_messages`（带
  `res/raw/chatflow_message.ogg` 提示音与震动）。
  证据：`docs/verification/artifacts/2026-09-03/bug2-lockscreen-notification.png`。

**0.3.30 三层加固**（用户复测仍无通知后的深度修复）：
1. **唤醒锁**：前台服务只提升进程优先级，不阻止息屏后 CPU 休眠与
   WiFi 低功耗断连——长轮询同步仍会停。新增原生 `chatflow/keepalive`
   通道，保活期间持有 PARTIAL WakeLock + 高性能 WifiLock
   （API 34+ 用 WIFI_MODE_FULL_LOW_LATENCY），MainActivity onDestroy 释放。
2. **看门狗**：`SyncKeepAliveService` 每 10 分钟重申前台服务与唤醒锁
   （系统静默回收后自愈），退后台/回前台生命周期亦重申。
3. **电池优化白名单引导**：登录后一次性弹窗引导"忽略电池优化"
   （`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`），MIUI 自启动指引写入文案；
   已加白/已引导则永不打扰。
4. **后台来电铃声**：新增 `calls_ring` 渠道（挂
   `res/raw/chatflow_ringtone.ogg`，Importance.max + 震动）；退后台来电
   由系统通知发声，应用内循环经 `SoundServiceCallAlertDriver.audible`
   门控静音（回前台自动恢复），杜绝双声。

**0.3.31 同步看门狗**（第四次修复，针对"后台一段时间后停收"）：
用户复测表明进程保活/唤醒锁均生效（常驻通知在、白名单已开），但退后台
一段时间后同步停摆、回前台立即恢复——SDK 同步循环存在悬挂路径（长轮询
连接黑洞、续环断裂、事务卡死）且无自愈。新增 `MatrixSyncWatchdog`
（`lib/features/matrix/matrix_sync_watchdog.dart`）：

- 心跳 = SDK `onSyncStatus` 的 waitingForResponse/processing/finished
  （健康长轮询 ≤40s 一跳）；
- 停跳 >2.5min → 踢 `oneShotSync`；>5min → `abortSync`（15s 超时兜底）
  + 重开 `backgroundSync` 强制重建循环 + 立即补一次同步拉回漏掉的消息；
- 全部行动打 `chatflow/syncwatchdog` 标签（release logcat 可见）：
  `adb logcat -s flutter | grep syncwatchdog` 可现场定位悬挂形态。

**边界与前置条件**：
- Android 14+ 对 dataSync 前台服务有每日约 6 小时配额，超时系统停服并
  退回"进程存活期"通知；回前台自动补启。
- 厂商 ROM（MIUI 等）需用户开启 **自启动** + **省电策略=无限制**，否则
  息屏数分钟后进程仍可能被杀（此为系统级限制，代码无法绕过）。
- 用户从最近任务划掉 App / 系统深度清理后，前台服务一并停止——该场景
  属推送通道（FCM/厂商推送）缺失的已知边界。

## 9. 已知限制（后续阶段）

1. **无推送通道**：未接入 FCM/APNs（服务端推送基础设施缺失）。APP 被杀后
   消息/来电不可达；后台通知依赖 dataSync 前台服务保活（见 §8），前台
   服务被停/被杀即不可达。
2. **iOS 自定义通知音**：需要把 CAF/WAV 注册进 Xcode bundle（无法在 Windows
   构建验证），本期 iOS 系统通知使用系统默认音；前台音效不受影响。
3. **Android 12+ CallStyle**：来电仍使用 full-screen-intent 方案。
4. **iOS CallKit/PushKit/灵动岛**：未实现（需 Mac 构建环境与 VoIP 推送）。
5. **Android 桌面角标**：自建 MethodChannel（`chatflow/badge`）+ 原生
   ShortcutBadger 1.1.22（flutter_app_badger 1.3.0 与项目 AGP 9 不兼容，已替换）；
   iOS 由 AppDelegate 写 `UIApplication.applicationIconBadgeNumber`。
   厂商启动器差异可能导致不生效，失败静默。
6. **每好友自定义音效**：第二阶段（PRD §44）。
7. **埋点**：仅本地 SharedPreferences 计数（PRD §63 事件名），不含消息内容；
   远端分析待基础设施。
8. `call_page.dart` 存在用户未提交改动，本期未触碰该文件。

## 9. 测试与验证（2026-09-03）

- 先红后绿：通知模块测试先行，模块缺失时 8 个测试文件加载失败（红）→
  实现后全绿。证据：`docs/verification/artifacts/2026-09-03/flutter-test-notification.log`。
- 门禁：`flutter analyze` 0 issues；`flutter test` 595 全过
  （`docs/verification/artifacts/2026-09-03/flutter-test-full.log`）；
  `dart format` 已应用。
- 覆盖的 PRD 断言：自己消息零反馈（§26/§52）、当前会话零提醒（§18/§53）、
  前台/后台路由（§18/§19）、@我/特别关注 P1（§27/§28）、静音与例外（§29）、
  勿扰跨午夜（§30）、隐私三档（§20/§45）、通话中静默（§40）、声音/震动独立开关
  （§38）、去重（§25/§66）、冷却（§41）、角标聚合（§35/§36）、资产完整性、
  通话铃声相位（§5/§9/§10）、三态切换（§44）。
