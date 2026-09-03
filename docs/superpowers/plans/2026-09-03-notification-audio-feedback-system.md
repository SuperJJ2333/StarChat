# ChatFlow 统一通知与音频反馈系统实施计划（Phase 1）

**状态：** 已批准
**日期：** 2026-09-03
**适用客户端：** `apps/mobile_flutter`（畅聊 ChatFlow）
**依据：** 《ChatFlow 通知与音频反馈系统 PRD V1.0》（用户提交）+ `docs/superpowers/specs/2026-08-12-starchat-product-modernization-design.md` §8.4 + `apps/mobile_flutter/AGENTS.md`

## 1. 背景与素材决策

- 仓库现状：无统一通知协调器；`flutter_local_notifications` 被 3 处独立使用（消息提醒 / 来电 / 好友申请）；`assets/SE/` 有 7 个 MP3 但未注册 pubspec、未被引用；无 FCM/APNs 推送依赖。
- 音效素材核对结论（2026-09-03，ffprobe 实测）：PRD 第一版 8 个核心音效仅能覆盖 5 个。用户决策：**缺失音效用现有素材顶替，正式素材到位后直接替换 `assets/sounds/` 对应文件，不改代码。**

| 源（assets/SE/） | 实测时长 | 处理 | 生成（assets/sounds/） |
| --- | --- | --- | --- |
| message_reminder_se.mp3 | 2.15s（头部静音 0.805s、尾部 0.622s） | 裁首尾静音 → 约 0.73s | message_received.mp3；拷贝顶替：message_attention / notification / mention |
| voice_message sending_se.mp3 | 0.51s | 裁静音 | message_sent.mp3 |
| video_call _ringtone_se.mp3 | 6.28s（循环段） | 原样 | call_video_incoming.mp3；拷贝顶替：call_voice_incoming |
| video_call _waiting _se.mp3 | 1.06s（循环段） | 原样 | call_outgoing.mp3；截短+淡出：call_connected（顶替） |
| video_call _hang-up_se.mp3 | 0.84s | 原样 | call_ended.mp3 |
| red_packet_opening_se.mp3 | 2.40s | 原样 | redpacket_open.mp3；拷贝顶替：redpacket_received / diamond_received / transfer_received |
| scan_se.mp3 | 0.42s | 原样 | scan.mp3（扫码 UI 反馈，PRD 清单外） |

另以 ffmpeg 转 OGG 放 `android/app/src/main/res/raw/`（chatflow_message / chatflow_attention / chatflow_mention / chatflow_system.ogg）作 Android 系统通知音。

## 2. 范围

### 本期交付

1. `lib/core/notification/` 统一通知模块（Coordinator / PolicyEngine / Deduplicator / CooldownGate / Preferences / AppStateManager / ForegroundSoundService / HapticService / BadgeService / InAppBanner）。
2. Android 系统通知渠道整合（chatflow_messages / chatflow_mentions / chatflow_system / chatflow_silent；同会话聚合 id=hash(roomId)）。
3. 登录后上下文式 POST_NOTIFICATIONS 权限申请（PRD §33 流程），收拢各 scheduler 的自动权限申请。
4. 通知与声音设置页 + 会话级 默认/静音/特别关注 三态（ConversationPreference v2 新增 `attention` 字段，向后兼容）。
5. 通话相位音效（ringing 循环 / connected / ended）、发送成功音、红包开启音、扫码音，统一经 Coordinator。
6. 单元测试（先红后绿）与 `flutter analyze` / `flutter test` / `dart format` 门禁。
7. `docs/NOTIFICATION_SYSTEM.md`、`docs/NOTIFICATION_QA_MATRIX.md`。

### 明确不做（后续阶段，文档如实标注）

- FCM/APNs 推送通道（服务端推送基础设施不存在；被杀状态通知不可达）。
- iOS CallKit/PushKit/ActivityKit/灵动岛原生实现（无 Mac 构建验证环境）。
- Android 12+ Notification.CallStyle 原生改造（保留现有 full-screen-intent 来电方案与 `calls`/`call-ongoing` 渠道）。
- iOS 自定义通知音（需 pbxproj 注册 bundle 资源并真机验证；本期 iOS 用系统默认音）。
- 每好友自定义通知音（PRD §44 第二阶段）。

## 3. 关键设计

- 事件入口：`sdkClient.onSync`（已核实 matrix 0.34.0：`SyncUpdate.rooms.join[roomId].timeline.events`；发出时房间内存状态已更新；CachedStreamController 无重放，但仍忽略订阅后首个 sync 与 originServerTs 陈旧事件防历史误报）。
- 复用既有纯逻辑：`ConversationReadState.isRoomOpen`（当前会话抑制）、`evaluateMuteNotification`（静音+@我/关注例外）、`preferenceForRoom`、`conversation_presentation.dart` 摘要助手（[图片]/[语音]/[红包] 等标签）。
- E2EE 边界：预览文本仅在本地解密后使用；系统通知正文按隐私三档裁剪（隐藏档显示"你收到了一条新消息"）；通知数据不进入业务 API。
- 自己消息（PRD §26/§52）：无通知、无声、无震动、无未读——仅允许前台 `message_sent` 反馈。
- 消息风暴（PRD §41/§42）：同会话声音冷却 2s、全局 600ms；后台同会话只更新同一通知。
- 去重（PRD §25/§66）：eventId TTL 10 分钟缓存，Matrix 与 Push 同事件只响一次。
- 通话中（PRD §40）：普通消息静默，仅特别关注允许极轻提示。
- 现有渠道 `calls` / `call-ongoing` / `changliao_message_reminders` / `changliao_friend_requests` 本期行为不变。
- 桌面角标：新增依赖 `flutter_app_badger 1.3.0`（锁版本）；Android 厂商启动器差异可能导致不生效，文档说明。
- `call_page.dart` 存在未提交本地改动，本期不触碰该文件。

## 4. 验收

- 纯逻辑单测覆盖：自己消息、当前会话、静音+例外、@我 P1、特别关注、勿扰跨午夜、隐私三档、通话中静默、P0–P4 映射、去重、冷却、偏好 round-trip、角标聚合、SoundType→asset 完整性。
- `flutter analyze` 0 issue、`flutter test` 全绿、`dart format` 幂等。
- PRD §64 QA 矩阵逐项标注：本期可测 / 需推送通道（pending）/ 需原生实现（pending）。
