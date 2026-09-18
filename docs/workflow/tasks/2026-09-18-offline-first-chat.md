# 2026-09-18 Offline First 聊天：进入会话不被网络阻塞 + 网络状态 + 消息等待发送

## 恢复入口

- 目标、用户授权来源及边界：用户直接指令（本会话）——“修复弱网/无网环境下无法进入好友加密会话的问题”，
  并给出 6 项要求（审查打开链路 / Matrix 私聊创建改成 Local First + pending conversation / 消息状态
  local·sending·waitingNetwork·failed·sent + 恢复自动重试 / 新增统一 NetworkStateManager /
  按错误类型改写提示且禁止“无法打开加密会话” / 补齐 4 条验收测试）。**明确禁止修改 Matrix 加密协议**，
  只允许优化 Room opening lifecycle、Network handling、Message retry state、UI error handling。
- 关联规范/ADR：[产品现代化设计 §弱网重试](../../superpowers/specs/2026-08-12-starchat-product-modernization-design.md#L445)、
  [移动交付工作流](../../runbooks/mobile-delivery-workflow.md)、
  [Room Opening Policy 文档](../../architecture/room-opening-policy.md)。
- 当前状态：**进行中**。已落地：RoomOpeningPolicy 本地已知即刻进入、私聊本地优先解析、
  pending conversation 页 + 后台仲裁 + outbox 自动发送、统一错误文案、`NetworkStateManager`（新文件，
  25 条单测）、组合根网络状态接线、无网/弱网进入的 9 条新测试。进行中：消息发送状态机
  （`waitingNetwork` + 网络恢复自动重试）。
- 负责人、工作树、文件所有权、源码 commit：本地工作树 `D:\pythonProject\outsource\StarChat`，分支 `main`。
  起点 `4d8c0008`。本任务拥有：
  `lib/app_home.dart`（打开路径 + 网络状态接线）、
  `lib/features/matrix/{room_opening_policy,direct_chat_controller,coordinated_direct_chat,direct_chat_entry,direct_chat_failure,room_navigation_coordinator,pending_conversation_page,matrix_e2ee_client(本地快照)}.dart`、
  `lib/features/matrix/room_page.dart`（initialOutbox + 发送状态呈现）、`lib/core/network_state_manager.dart`、
  以及对应测试。**发送状态机文件由子代理并行修改**：`room_timeline_controller.dart`、
  `ui/chat/wechat_message_bubble.dart`、`ui/chat/super_emoji_message.dart`。
- 最后更新时间（含时区）：2026-09-18（Asia/Hong_Kong）。
- 下一条具体操作、必要输入、阻断的验收 ID：等待发送状态机子任务结束后，重跑
  受影响套件 → 全量 `flutter test` → `pytest tests/mobile` → 记录证据并推送。
  当前无阻断项。

## 验收台账（用户 4 条 + 6 项要求）

| ID | 场景及预期 | 实现 | 测试及证据 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- |
| A1 | 无网络进入好友聊天 → 可以进入聊天页面 | 本地命中（SDK 本地库安全快照 / intent 房间号 + 本地存在）立即进入；未命中进入 PendingConversationPage | `offline_first_opening_test.dart`（本地命中零网络、本地缺失返回 null 不抛错、pending 页立即渲染） | 待真机 |
| A2 | 弱网进入好友聊天 → 不阻塞导航 | RoomOpeningPolicy：本地已知（未 joined）→ `openNow('local_known')`，零有界等待 | 同上 + `room_opening_policy_test.dart`（本地已知→零等待；本地完全未知→仍有界等待一次） | 待真机 |
| A3 | 弱网发送消息 → 显示等待发送 | `RoomDeliveryState` 增加 `local`/`waitingNetwork`；网络类失败不再落到红色感叹号 | 子任务测试（`offline_send_state_test.dart`） | 待真机 |
| A4 | 恢复网络 → 自动发送成功 | `NetworkStateManager` 恢复事件驱动 `waitingNetwork` 行按原 txid 自动重发 | 同上 + `network_state_manager_test.dart`（25 条） | 待真机 |
| B1 | 审查并改造 `_openManagedRoom*` 链路 | `_resolveDirectMessageTarget` 改为 `_resolveLocalDirectMessageTarget`（只读本地）；新增 `_openPendingConversation` | `offline_first_opening_test.dart`、`app_home.dart` 改动 | — |
| B2 | 私聊创建 Local First + pending conversation | `DirectChatGateway.tryLocalDirectChat/localRoomHint`（零网络、不抛错）；`PendingConversationPage` + 后台 `directChats.open` + `PendingConversationResult` 回传 | 同上；pending 页回传 `roomId + queued` 测试 | 队列仅内存（重启丢失），已记录 |
| B3 | 统一 NetworkStateManager（online/weak/offline/recovering） | 新文件 `lib/core/network_state_manager.dart`；组合根 `_bindNetworkState` 复用 MatrixSyncWatchdog 信号投影 | `network_state_manager_test.dart` 25 条；`app_home.dart` 接线 | — |
| B4 | 错误提示按类型改写、禁止旧标题 | `direct_chat_failure.dart`：offline/weak/server/crypto 各自标题与文案，`无法打开加密会话` 仅存在于历史注释 | `direct_chat_failure_test.dart`（更新 + 新增分类词表与“旧口径不出现”断言） | — |
| B5 | 不改 Matrix 加密协议 | 未触碰 SDK fork、Olm/Megolm、密钥、房间创建协议；只改打开生命周期/网络/状态/文案 | 变更文件清单 + 架构守卫测试 | — |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 文件位置 | 发布观察时间 |
| --- | --- | --- | --- | --- |
| Flutter 客户端（本地） | Flutter 3.44.9 / Dart 3.12.2 | `4d8c0008` + 本任务改动 | 见“恢复入口”文件所有权 | 未构建、未发布 |

- 命令与退出码（阶段性）：
  - `flutter analyze lib test` → **No issues found**
  - `flutter test --timeout 120s`（全量）→ **`+3221: All tests passed!`**（退出码 0；改动前 3173）
  - `flutter test test/features/matrix/offline_first_opening_test.dart` → **+9 全通过**
  - `flutter test test/features/matrix/offline_send_state_test.dart` → **+12 全通过**
  - `flutter test test/core/network_state_manager_test.dart` → **+25 全通过**
  - `pytest tests/mobile -q` → **68 passed / 1 failed（非本任务：`test_android_ci_workflow_exists_and_pins_flutter`，
    由同日另一会话提交 `bd28dbff` 改动 `.github/workflows/android-ci.yml` 引起，守卫测试自 `f518dc7c` 未变）**
- 未执行项：真机验收、构建发布（本任务只做客户端逻辑修复，是否出包/发布由用户决定）、`scripts/verify.ps1` 全量
  （改动只在 Flutter 客户端；已用 analyze + 全量 flutter test + tests/mobile 覆盖）。
- 复用依据：无（本任务改动触及客户端共享逻辑，门禁全部重跑）。

## 阶段计时

| 阶段 | 开始 | 结束 | 主动/工具/外部等待/返工 | 结果 |
| --- | --- | --- | --- | --- |
| 只读侦察（4 路并行：打开链路/发送状态/私聊解析/网络状态） | 2026-09-18 | 2026-09-18 | 工具等待（4 个子代理并行） | 得到 file:line 级现状图 |
| 实现：策略 + 本地优先 + pending 页 + 错误文案 | 2026-09-18 | 2026-09-18 | 主动 + 返工（接口新增导致 3 个测试假实现/断言需同步更新） | 9 条新测试转绿，既有套件修复 |
| 实现：NetworkStateManager + 组合根接线 | 2026-09-18 | 2026-09-18 | 工具等待（子代理 25 条测试） | 完成 |
| 实现：发送状态机 + 自动重试 | 2026-09-18 | 进行中 | 工具等待（子代理） | 待收口 |
| 门禁 + 记录 + 推送 | 2026-09-18 | 进行中 | — | 待收口 |

## 交接与回退

- 已确认根因：好友「发消息」在 `_resolveDirectMessageTarget` 里 **await** 了 `directChats.open`
  （业务目录 canonical 查询 + Matrix join/health/claim/publish，均可能阻塞数秒到 15 秒），弱网/无网时抛错 →
  唯一 catch 点弹「无法打开加密会话」；而 RoomPage 需要真实 SDK Room，本地没有房间时无法渲染，
  因此必须先落地 pending conversation 才能做到“不阻塞进入”。
- 已排除假设：不是导航协调器重复打开（按 roomId 去重）；不是 RoomPage 时间线联网（时间线读本地 DB）；
  不是策略层等待（策略只对本地完全未知的房间做 5 秒有界等待）。
- 待办及验收失败项：无失败项；发送状态机子任务完成后需重跑全量门禁（A3/A4 证据待补）。
- 已发布与仅候选的区别：**仅代码改动，未构建、未发布**。
- 回退：按文件 `git checkout <起点> -- <文件>` 即可；pending 页与 NetworkStateManager 为新增文件，删除即回到旧行为；
  策略层契约变更有对应测试记录（`local_known`）。
- 下次恢复先检查的事实：① 发送状态机是否已收口并通过 `offline_send_state_test.dart`；
  ② 全量 `flutter test` 与 `pytest tests/mobile` 是否在最新树上全绿；③ 是否需要出包给用户真机验证
  （A1–A4 全部标注“待真机”）。
