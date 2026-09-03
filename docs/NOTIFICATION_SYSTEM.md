# ChatFlow 统一通知与音频反馈系统

**适用客户端：** `apps/mobile_flutter`（畅聊 ChatFlow）
**实现日期：** 2026-09-03（0.3.32 于 2026-09-04 更新后台可靠性章节）
**依据：** 《ChatFlow 通知与音频反馈系统 PRD V1.0》§1–§70
**实施计划：** `docs/superpowers/plans/2026-09-03-notification-audio-feedback-system.md`、
`docs/superpowers/plans/2026-09-04-background-notification-reliability.md`
**验收矩阵：** `docs/NOTIFICATION_QA_MATRIX.md`

---

## 1. 架构总览

```text
Matrix Sync (sdkClient.onSync)                  [Push 旁路：FCM/APNs → Sygnal（凭据待配置）]
        ↓
MatrixNotificationEventSource            ← 事件事实：自己消息/当前会话/静音/特别关注/@我
        ↓ IncomingNotification
NotificationCoordinator（唯一入口，由 NotificationSystemBootstrapper 单例装配）
        ├─ NotificationDeduplicator       ← eventId 去重（PRD §25/§66；默认持久化 24h）
        ├─ NotificationPolicyEngine       ← 纯函数决策（PRD §22）
        ├─ SoundCooldownGate              ← 同会话 2s / 全局 600ms（PRD §41）
        ↓ NotificationDecision
        ├─ InAppBannerController + InAppBannerOverlay   ← 前台横幅（PRD §7）
        ├─ ForegroundSoundService (audioplayers)        ← 前台音效
        ├─ HapticService                                 ← 震动（PRD §37）
        ├─ FlutterLocalSystemNotificationPresenter       ← 后台系统通知（PRD §19；v2 heads-up 渠道）
        └─ BadgeService (flutter_app_badger)             ← 桌面角标（PRD §35/§36）

NotificationDiagnostics                  ← 全链路结构化诊断（脱敏，设置页可查看复制）
ForegroundServiceArbiter                 ← 消息保活(dataSync) 与通话中(mic|camera) 前台服务仲裁
```

- 所有代码位于 `apps/mobile_flutter/lib/core/notification/`；Matrix 适配层在
  `lib/features/matrix/matrix_notification_event_source.dart`；推送在
  `lib/features/push/`。
- **业务页面禁止直接 `AudioPlayer().play(...)` 或创建系统通知**（PRD §2/§68-2/3）。
  纯前台 UI 反馈（发送成功/红包开启/扫码）经 `NotificationFeedback.shared.play(...)`
  间接进入协调器（检查声音开关后播放）。
- 组合根：`lib/app_home.dart` 的 `_AppHomeState._startNotificationSystem()`
  ——登录会话内经 `NotificationSystemBootstrapper` **只装配一次**
  （一个 eventSource + 一个 coordinator）；启动失败置 needsRetry，由下一次
  生命周期恢复重试（此前"可重试"注释并不存在实际路径）。

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

| Channel ID | 用途 | Importance | 声音（res/raw） | 备注 |
| --- | --- | --- | --- | --- |
| `chatflow_messages_v2` | 普通消息 | **HIGH** | chatflow_message.ogg | 渠道级震动；0.3.32 起启用（Heads-up 顶部弹窗） |
| `chatflow_mentions` | @我 | HIGH | chatflow_mention.ogg | |
| `chatflow_attention` | 特别关注 | HIGH | chatflow_attention.ogg | |
| `chatflow_system` | 系统业务通知 | DEFAULT | chatflow_system.ogg | |
| `chatflow_silent` | 静默同步 | LOW | 无声 | 静音/勿扰后台仍入通知中心 |
| `chatflow_messages` | （legacy） | DEFAULT | chatflow_message.ogg | 0.3.30 及之前的消息渠道；**保留不删除**、不再承载通知、新安装不再创建 |

渠道 v2 迁移原因：Android 渠道创建后重要性/声音不可由应用修改，老安装的
v1 渠道（IMPORTANCE_DEFAULT，无顶部弹窗）无法原地升级到 heads-up——必须
换新渠道 ID。用户对 v2 渠道的自定义（静音/降级）只能由用户在系统设置中
恢复；设置页提供「消息通知渠道设置」深链直达
（`Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS`，MainActivity
`chatflow/notification` 通道）。

既有渠道行为不变：`calls` / `calls_ring` / `call-ongoing`（来电全屏意图、
系统铃声与通话中前台服务）、`changliao_message_reminders`（定时提醒）、
`changliao_friend_requests`（好友申请）。
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

**0.3.32 后台通知可靠性修复**（2026-09-04，见
`docs/superpowers/plans/2026-09-04-background-notification-reliability.md`）：
在对"后台/锁屏/进程被杀收不到通知"的根因复查中发现并修复了通知管线自身的
五个缺陷（与保活层叠加放大了故障）：

1. **单例初始化**：AppHome.initState 曾并发调用 `_startNotificationSystem()`
   两次——两套 eventSource/coordinator/deduplicator，首套泄漏整个登录会话
   （双声/双震/双系统通知）。现由 `NotificationSystemBootstrapper`
   （Future 备忘录）保证一次装配；失败置 needsRetry 并在生命周期恢复时
   重试（真正实现了此前注释承诺的重试路径）。
2. **前台服务仲裁**：flutter_local_notifications 全局只有一个 Android
   ForegroundService——通话结束 `hideOngoing()` 的 `stopForegroundService`
   会同时杀掉消息保活（keepalive 状态仍 running，仅靠 10 分钟看门狗自愈）。
   现 `SyncKeepAliveService` 与 `CallNotifications` 共用
   `ForegroundServiceArbiter`：通话释放所有权后仲裁器**重申**保活通知
   （41003）而非停服；全部释放才真正 stop。
3. **渠道 v2**：`chatflow_messages` 为 IMPORTANCE_DEFAULT 无 Heads-up——
   新渠道 `chatflow_messages_v2`（HIGH + 渠道级震动 + message 音）；v1 保留
   不删除（见 §3）。
4. **跨重启去重**：`NotificationDeduplicator` 改为可插拔 store，组合根注入
   SharedPreferences 持久化实现（TTL 24h）——为推送通道防"系统推送已展示、
   冷启动同步又提醒一次"奠基；推送点击（`PushTapRouter`）与协调器共用同一
   store。
5. **结构化诊断**：`NotificationDiagnostics`（脱敏：无正文/Token/密钥，
   roomId/eventId 仅 12 字符前缀）区分 6 个层级——sync 到达 / 策略与抑制
   原因（静音/当前会话/勿扰/总开关/通话中）/ 系统通知调用成败 / 权限状态 /
   渠道状态（原生 `getChannelState` 读取用户改过的真实配置）/ 前台服务
   仲裁动作。设置页「通知诊断」可查看与复制（最近 120 条，跨重启保留）。
6. **权限生命周期**：回前台与设置页 resume 时重查权限状态（从系统设置
   返回后立即反映）；永久拒绝场景经设置页深链直达应用/渠道通知设置；
   移除 `FriendRequestNotifier` 抢先弹系统权限框（违反 PRD §33 且与登录
   引导双弹窗）。
7. **推送客户端就绪**（凭据待配置）：Matrix Pusher 注册
   （`lib/features/push/`，format=event_id_only）、FCM 条件接入
   （缺 google-services.json 时构建与运行零行为变化）、推送点击冷启动
   路由、登出注销。服务端 Sygnal 网关模板就绪（`infra/sygnal/`）。
   配置步骤与缺失凭据清单见 `docs/PUSH_SETUP.md`。

**边界与前置条件**：
- **dataSync 前台服务不是长期可靠方案**：Android 14+ 对 dataSync 前台服务
  有每日约 6 小时配额，超时系统停服并退回"进程存活期"通知；回前台自动
  补启。进程被杀后的可达性必须依赖推送通道（FCM/APNs，凭据待配置）。
- 厂商 ROM（MIUI 等）需用户开启 **自启动** + **省电策略=无限制**，否则
  息屏数分钟后进程仍可能被杀（此为系统级限制，代码无法绕过）。
- 用户从最近任务划掉 App / 系统深度清理后，前台服务一并停止——在推送
  凭据配置完成前，该场景仍不可达（推送链路就绪后由系统通知兜底）。

## 9. 已知限制（后续阶段）

1. **推送通道待凭据激活**：客户端 Pusher 注册/FCM 接线与服务端 Sygnal
   模板均已就绪，但 FCM（google-services.json + 服务账号）与 APNs
   （证书/密钥 + entitlement 签名）凭据缺失，尚未激活——不得硬编码、
   伪造或宣称完成。缺失清单与人工步骤：`docs/PUSH_SETUP.md`。
   凭据配置前：APP 被杀后消息/来电仍不可达。
2. **iOS 自定义通知音**：需要把 CAF/WAV 注册进 Xcode bundle（无法在 Windows
   构建验证），本期 iOS 系统通知使用系统默认音；前台音效不受影响。
3. **Android 12+ CallStyle**：来电仍使用 full-screen-intent 方案；推送
   兜底通知（进程被杀时）为普通 heads-up，未用 CallStyle。
4. **iOS CallKit/PushKit/灵动岛**：未实现（需 Mac 构建环境、APNs VoIP
   推送与 Apple Developer 凭据；设计见 `docs/PUSH_SETUP.md` §来电）。
   不得用普通 APNs 消息推送冒充 VoIP 推送。
5. **Android 桌面角标**：自建 MethodChannel（`chatflow/badge`）+ 原生
   ShortcutBadger 1.1.22（flutter_app_badger 1.3.0 与项目 AGP 9 不兼容，已替换）；
   iOS 由 AppDelegate 写 `UIApplication.applicationIconBadgeNumber`。
   厂商启动器差异可能导致不生效，失败静默。
6. **每好友自定义音效**：第二阶段（PRD §44）。
7. **埋点**：仅本地 SharedPreferences 计数（PRD §63 事件名），不含消息内容；
   远端分析待基础设施。

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
