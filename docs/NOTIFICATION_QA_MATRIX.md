# ChatFlow 通知系统 QA 验收矩阵

**日期：** 2026-09-03
**状态图例：** ✅ 本期已实现并有自动化断言｜🧪 本期已实现，需真机手工验证｜
⏳ 依赖推送通道（FCM/APNs，后续阶段）｜📱 依赖原生实现（CallKit/LiveActivity/CallStyle，后续阶段）

## PRD §64 场景矩阵

| 场景 | Android | iOS | 自动化证据（测试） |
| --- | --- | --- | --- |
| 前台收到私聊（横幅+声音+轻震+角标，不出系统通知） | ✅ | ✅ | notification_policy_engine_test（§18 组）、notification_coordinator_test |
| 当前会话收到消息（无横幅/声音/震动/角标） | ✅ | ✅ | notification_policy_engine_test（§18/§53 组） |
| 后台私聊（系统通知+渠道声，Flutter 不发声） | ✅ | ✅ | notification_coordinator_test（后台组）+ Mi 6 真机（dataSync 前台服务保活，2026-09-03） |
| 锁屏私聊 | ✅ | ✅ | Mi 6 息屏实测：锁屏显示通知卡片（bug2-lockscreen-notification.png） |
| 后台/锁屏来电铃声 | ✅* | 🧪 | 机制同消息（前台服务保活→来电信令可达→应用内铃声循环+全屏意图）；*Mi 6 息屏实测消息链路，来电待双机验收 |
| 消息同步保活前台服务 | ✅ | ✅ | sync_keepalive_service_test 5 用例 + Mi 6 实测常驻通知 41003 |
| 自己发送消息（无通知/未读/角标；可选发送音） | ✅ | ✅ | policy §26/§52 组 + coordinator 自己消息组 |
| 群聊消息 | ✅ | ✅ | policy 普通消息组 |
| @我（P1、mention 音、双震、mentions 渠道） | ✅ | ✅ | policy §28 组 |
| 特别关注（P1、attention 音、attention 渠道） | ✅ | ✅ | policy §27 组 |
| 静音群聊（静默+通知中心保留+未读计数） | ✅ | ✅ | policy §29 组 |
| 静音群 @我例外 | ✅ | ✅ | policy §29 例外组 |
| 勿扰时间窗（含跨午夜） | ✅ | ✅ | policy §30 组 + preferences 勿扰窗口测试 |
| 系统 DND / 通知权限拒绝（权限降级提示） | ✅ | ✅ | 实现于设置页；OS 侧行为以系统为准（§62） |
| 语音来电（语音铃声循环+震动） | ✅ | ✅ | call_controller_test 被叫语音铃声断言 |
| 视频来电（视频铃声循环） | ✅ | ✅ | call_controller_test 被叫视频铃声断言 |
| 主叫等待音 / 接通确认音 / 结束音 | ✅ | ✅ | call_controller_test 主叫+提示音断言 |
| 通话中收到消息（普通静默、特别关注轻提示） | ✅ | ✅ | policy §40 组 |
| 通话中切后台（前台服务+通知保留） | ✅（既有） | ✅（既有） | 既有 CallNotifications 行为，本期未改动 |
| 消息风暴（同会话 2s 冷却 / 全局 600ms） | ✅ | ✅ | sound_cooldown_gate_test + coordinator 冷却组 |
| 双通道同一 eventId（只响一次） | ✅ | ✅ | notification_deduplicator_test + coordinator 去重组 |
| 同会话后台聚合（同一通知 ID 更新） | ✅ | ✅ | notificationIdForConversation 哈希 + 聚合实现 |
| 通知隐私三档 | ✅ | ✅ | policy §20/§45 组 + coordinator 隐私传导组 |
| 桌面角标聚合（静音会话按设置计入；手动未读不计入） | ✅ | ✅ | badge_service_test |
| 会话三态（默认/静音/特别关注；互斥） | ✅ | ✅ | group_chat_info_test、direct_chat_info_test |
| 权限上下文式申请（登录后弹说明→系统弹窗） | 🧪 | 🧪 | 实现于 AppHome._primeNotificationPermission |
| 发送成功音 / 红包开启音 / 扫码音 | 🧪 | 🧪 | NotificationFeedback 接入；真机听感验证 |
| 通知点击进入会话 | 🧪 | 🧪 | 系统通知 payload→RoomPage 实现；真机验证 |
| APP 被杀后收到消息 | ⏳ | ⏳ | 依赖 FCM/APNs 推送通道 |
| APP 被杀后收到来电 | ⏳ | ⏳ | 依赖 VoIP 推送（iOS PushKit） |
| 多设备 Read Receipt | ✅（既有） | ✅（既有） | conversation_read_state_test（既有） |

## PRD §65 性能指标现状

| 指标 | 目标 | 现状 |
| --- | --- | --- |
| NotificationCoordinator 决策 | P95 < 10ms | 纯同步函数 + 内存查表，满足（单测毫秒级） |
| Event → Sound（前台） | P95 < 100ms | 事件源直接读内存房间状态；audioplayers 低延迟模式；未做真机 P95 采样（🧪） |
| Event → UI | P95 < 150ms | 既有会话列表路径；未做真机采样（🧪） |
| 不为通知等待头像/网络 | 是 | 横幅使用占位头像；预览取本地已解密事件 |

## 真机手工验证清单（🧪 项）

1. Android 13+：登录后首次弹权限说明 → 允许/拒绝两条路径；拒绝后设置页降级卡。
2. Android：chatflow_* 五渠道在系统设置中的可见性与声音正确性（自定义 OGG）。
3. 后台/锁屏消息：横幅不出现、系统通知出现且只响一次；锁屏隐私三档生效。
4. 语音/视频来电铃声循环与接通/结束提示音听感；通话中收普通消息静默。
5. iOS：系统通知默认音（本期无自定义音）、角标（UIApplication badge）、
   静音键下前台音效静默（ambient 类别）。
6. 桌面角标：华为/小米/OPPO/vivo 启动器差异（flutter_app_badger 尽力而为）。
7. 发送成功音、红包开启音、扫码音听感与开关联动（声音开关关闭后静默）。

## 已知不满足项（⏳/📱）

- 被杀后消息/来电：待服务端推送基础设施（业务后端 notification 模块 + FCM/APNs
  客户端接入）后补齐；届时 Matrix 与 Push 双通道去重（已实现）直接生效。
- iOS CallKit/PushKit/灵动岛、Android CallStyle：原生阶段实现。
- iOS 自定义通知音（CAF 进 bundle）：需 Mac 构建验证。
