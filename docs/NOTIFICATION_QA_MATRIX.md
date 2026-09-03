# ChatFlow 通知系统 QA 验收矩阵

**日期：** 2026-09-03（0.3.32 于 2026-09-04 增补后台可靠性行）
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
| 消息同步保活前台服务 | ✅ | ✅ | sync_keepalive_service_test 9 用例 + Mi 6 实测常驻通知 41003 |
| 通知系统单例装配（登录会话仅一套 coordinator/eventSource） | ✅ | ✅ | notification_system_bootstrapper_test（并发/重复只装配一次；失败→生命周期重试） |
| 通话结束不停止消息保活（前台服务仲裁） | ✅ | ✅ | foreground_service_arbiter_test（keepalive+call 集成：释放通话→重申 41003 非 stop；看门狗重申不顶掉通话通知） |
| 普通消息 Heads-up 顶部弹窗（chatflow_messages_v2，HIGH+渠道级震动） | ✅ | n/a | system_notification_channel_v2_test（规格/映射/legacy 保留不删除）；真机弹窗效果 🧪 |
| 通知诊断（6 层级脱敏日志，设置页可查看） | ✅ | ✅ | notification_diagnostics_test（阶段/脱敏/容量/持久化）+ coordinator 抑制原因埋点 |
| 跨进程重启去重（推送已展示→同步不二次提醒） | ✅ | ✅ | notification_deduplicator_persistence_test（同 store 双实例抑制；TTL；持久层只存 eventId→时间戳） |
| 推送点击冷启动路由（eventId 先去重，会话就绪后进入房间） | ✅ | ✅ | push_tap_router_test（挂起/就绪/reset/防双击/载荷白名单） |
| Matrix pusher 注册/Token 轮换/登出注销（event_id_only） | ✅ | ✅ | matrix_pusher_service_test（注册/幂等/刷新/注销/无网关与无 Token 降级/E2EE 数据白名单） |
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
| 权限上下文式申请（登录后弹说明→系统弹窗；单飞不双弹） | 🧪 | 🧪 | 实现于 AppHome._primeNotificationPermission；FriendRequestNotifier 抢先申请已移除 |
| 权限回前台/设置页返回重查（含永久拒绝→应用/渠道设置深链） | ✅ | ✅（app-settings） | 设置页 WidgetsBindingObserver resume 重查 + MainActivity openChannelSettings/getChannelState；渠道深链真机验证 🧪 |
| 发送成功音 / 红包开启音 / 扫码音 | 🧪 | 🧪 | NotificationFeedback 接入；真机听感验证 |
| 通知点击进入会话 | 🧪 | 🧪 | 系统通知 payload→RoomPage 实现；真机验证 |
| APP 被杀后收到消息 | ⏳ | ⏳ | 客户端 Pusher/FCM 代码与服务端 Sygnal 模板已就绪，**凭据未配置**（docs/PUSH_SETUP.md §2）；不得宣称完成 |
| APP 被杀后收到来电 | ⏳ | ⏳ | Android：高优先级推送+heads-up 兜底（代码就绪，待凭据）；iOS：需 PushKit+CallKit（未实现，不得用普通 APNs 冒充） |
| 多设备 Read Receipt | ✅（既有） | ✅（既有） | conversation_read_state_test（既有） |

## PRD §65 性能指标现状

| 指标 | 目标 | 现状 |
| --- | --- | --- |
| NotificationCoordinator 决策 | P95 < 10ms | 纯同步函数 + 内存查表，满足（单测毫秒级） |
| Event → Sound（前台） | P95 < 100ms | 事件源直接读内存房间状态；audioplayers 低延迟模式；未做真机 P95 采样（🧪） |
| Event → UI | P95 < 150ms | 既有会话列表路径；未做真机采样（🧪） |
| 不为通知等待头像/网络 | 是 | 横幅使用占位头像；预览取本地已解密事件 |

## 真机手工验证清单（🧪 项）

1. Android 13+：登录后首次弹权限说明 → 允许/拒绝两条路径；拒绝后设置页降级卡
   （0.3.32 起含回前台/设置页返回后的权限状态重查）。
2. Android：chatflow_* 渠道在系统设置中的可见性与声音正确性（自定义 OGG）；
   **0.3.32 老安装升级后确认新渠道 chatflow_messages_v2 生效（Heads-up 弹窗+
   提示音+震动），旧渠道 chatflow_messages 不再出现新通知**；设置页
   「消息通知渠道设置」深链直达 v2 渠道页。
2a. 通话挂断后消息仍可达：通话中收消息→挂断→确认同步保活未被停止
   （常驻通知 41003 回写、`chatflow/notif-diag` fgs 日志重申记录）。
2b. 设置 → 通知与声音 → 通知诊断：查看/复制脱敏日志（sync 到达、抑制原因、
   system_show 成败、权限、渠道、fgs 各层级条目）。
3. 后台/锁屏消息：横幅不出现、系统通知出现且只响一次；锁屏隐私三档生效。
4. 语音/视频来电铃声循环与接通/结束提示音听感；通话中收普通消息静默。
5. iOS：系统通知默认音（本期无自定义音）、角标（UIApplication badge）、
   静音键下前台音效静默（ambient 类别）。
6. 桌面角标：华为/小米/OPPO/vivo 启动器差异（flutter_app_badger 尽力而为）。
7. 发送成功音、红包开启音、扫码音听感与开关联动（声音开关关闭后静默）。

## 已知不满足项（⏳/📱）

- 被杀后消息/来电：客户端（pusher 注册/FCM 接线/冷启动路由/持久去重）与
  服务端（Sygnal compose + 模板 + homeserver include_content=false）均已就绪，
  **卡在凭据**（google-services.json、FCM 服务账号、APNs .p8/entitlement、
  生产网关域名与部署授权）——清单与步骤见 docs/PUSH_SETUP.md，未配置前不标完成。
  凭据就绪后 Matrix 与 Push 双通道去重（已实现并有测试）直接生效。
- iOS CallKit/PushKit/灵动岛、Android CallStyle：原生阶段实现（设计见
  docs/PUSH_SETUP.md §7）。
- iOS 自定义通知音（CAF 进 bundle）：需 Mac 构建验证。
- dataSync 前台服务受 Android 14+ 每日约 6 小时配额限制：非长期方案，
  长期可达性以推送通道为准（如实记录，不宣称"永久可靠"）。
