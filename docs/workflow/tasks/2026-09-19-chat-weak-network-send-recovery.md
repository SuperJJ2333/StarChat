# 任务记录：聊天弱网发送反馈与房间瘫痪修复（2026-09-19）

## 恢复入口

- 目标、用户授权来源及边界：用户 2026-09-19 会话授权。目标：(1) 弱网/断网发送消息必须**及时**显示红色感叹号警告（气泡级，点击重发）；(2) 网络恢复后房间必须能自动恢复发送（修复"房间瘫痪"）；(3) **不再弹网络类警告弹窗**。用户明确修订：发送中**不**显示转圈（不增加加载感知）。自动重发机制保留。范围边界：本任务只拥有**聊天弱网修复（WS-A）+ 通讯录标签页收尾（WS-B0）**；页面加载模型其余项（入群确认/红包明细/朋友圈设置等）由**另一并行会话**按同一审计清单执行（其已提交 1104cf3f 搜索、c1aa22f3 邀请页、8dfdca24 审计文档更新；58c3dde0 动态草稿为本任务开始前已落地），本任务已按"不得并发编辑同一文件"规则退出该区域并撤销了对 `test/features/profile/invite_history_controller_test.dart` 的追加。
- 关联计划/ADR：本文件即经用户确认的执行计划（会话内）；关联 `docs/verification/2026-09-19-offline-first-audit.md`、`docs/workflow/tasks/2026-09-18-offline-first-chat.md`（前作：waitingNetwork 状态机、pending conversation）。
- 当前状态：实现 + 定向验证完成；全量 flutter test / verify.ps1 进行中。
- 负责人、工作树、文件所有权、源码commit：基于 3bedc5ffe7adc3575554ed40a68d42a8f1af98ec。本任务所有文件：`apps/mobile_flutter/lib/core/network_state_manager.dart`、`lib/features/matrix/room_timeline_controller.dart`、`lib/features/matrix/matrix_e2ee_client.dart`、`lib/features/matrix/matrix_client_factory.dart`、`lib/features/matrix/room_open_failure_feedback.dart`、`lib/features/matrix/room_page.dart`（仅注释）、`lib/app_home.dart`、`lib/ui/chat/wechat_message_bubble.dart`、`third_party/matrix/lib/src/utils/http_timeout.dart`、`third_party/matrix/CHATFLOW_PATCH.md`、`UI_DESIGN.md`、`test/features/matrix/offline_send_state_test.dart`、`test/core/network_state_manager_test.dart`、`test/features/matrix/room_opening_policy_test.dart`。
- 最后更新时间（含时区）：2026-09-19T09:40+08:00
- 下一条具体操作、必要输入、阻断的验收 ID：提交本任务工作树改动（用户未授权前不代提交）；真机弱网/断网验收（A1-A7、B0，需用户设备）。**移交提示**：页面加载模型剩余项由并行会话执行中（其 09:57 正在改红包明细页），本任务不再进入 features/ 页面区域；若并行会话完成后需复核 verify.ps1，请在其提交落地后单独重跑。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| A1 | 断网时发送：立即出红色感叹号（不空等传输层） | `_dispatch` 派发前检测 `NetworkState.offline` → 抛 `SocketException` → `waitingNetwork`，不触达传输层 | `offline_send_state_test.dart` 离线快速失败用例（红→绿） | 未发布 | 待真机 |
| A2 | 弱网悬挂：~20s 护栏后出红叹号，后续消息不受阻（房间不瘫痪） | `RoomTimelineController.sendDispatchTimeout`（默认 20s）包裹派发 await，超时转 `waitingNetwork`；`sendFuture.ignore()` 防未处理异常 | 同上悬挂护栏用例（红→绿） | 未发布 | 待真机 |
| A3 | 网络失败归类为可自动重发（不再误判终局失败） | 新增 `MessageSendNetworkException`（`core/network_state_manager.dart`）；SDK 发送路径 null→该类型（文本/转账/红包/媒体/retry）；分类器识别 | `network_state_manager_test.dart` 分类器用例；既有 waitingNetwork 自动重发组全绿 | 未发布 | 待真机 |
| A4 | 气泡视觉：waitingNetwork 与 failed 一致显示红色感叹号+点击重发；sending 保持无标记（用户修订：不转圈） | `wechat_message_bubble.dart` waitingNetwork 分支改为红叹号（key `message-delivery-waiting` 保留）；`UI_DESIGN.md §7` 词表同步修订 | 气泡外观组用例（断言时钟/文案移除、红叹号出现、点击重发） | 未发布 | 待真机 |
| A5 | SDK 弱网黑洞不再卡死房间发送队列 | `third_party/matrix/lib/src/utils/http_timeout.dart`：`inner.send()` 加 timeout；`sendTimelineEventTimeout` 组合根调紧 20s；补丁记录 `CHATFLOW_PATCH.md` 2026-09-19 条目 | 由 A2 行为用例+全量 SDK 回归覆盖（`sdk_stale_send_selfheal_test.dart` 绿） | 未发布 | 待真机 |
| A6 | 打开会话失败不再弹模态弹窗 | `room_open_failure_feedback.dart` 改为 `showRoomOpenFailureToast`（非阻断、无按钮）；`app_home._openManagedRoomRequest` 适配 + 2s single-flight | `room_opening_policy_test.dart`：toast 可见、无 `CupertinoAlertDialog`、无重试按钮、架构守卫（红→绿） | 未发布 | 待真机 |
| A7 | 服务不可达不再被误报为传输可用 | `app_home._bindNetworkState`：`serviceUnavailable` → `serverReachable:false`、不再置 `transportAvailable:true` | 依赖既有 watchdog/网络状态机测试回归（全绿）；无独立新用例（组合根接线层） | 未发布 | 待真机 |
| B0 | 标签列表页冷启动断网仍展示上次标签（审计 L1 缺口收尾） | 新增 `contact_tag_snapshot_store.dart`（InMemory+SharedPreferences，`contact.tags.v1`，账号 scope 校验）；`ContactTagsPage` 改快照优先状态机（失败不清空、成功才落盘）；`contacts_page` 注入 scopeResolver；`app_home` 启动 ensureLoaded | `contact_tag_cache_test.dart` 8 用例（含断网冷启动快照、账号切换保护、成功写回；红→绿） | 未发布 | 待真机 |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| Flutter 分析 | flutter analyze：No issues found（2026-09-19T09:39+08:00，23.0s；干净树复跑结果待回填） | 工作树（基线 3bedc5ff，其上已有并行会话 1104cf3f/c1aa22f3/8dfdca24） | - | - | - |
| 定向测试（WS-A） | offline_send_state + network_state_manager + outbox 目录 + outbox_send_flow + pending_conversation_outbox + room_page_presentation + direct_chat_failure + sdk_stale_send_selfheal = 102 通过 / 0 失败 | 同上 | - | - | - |
| room_opening_policy_test | 22 通过 / 0 失败 | 同上 | - | - | - |
| 全量 flutter test（WS-A 改动后首跑） | 3403 通过 / 0 失败（约 2 分 16 秒，2026-09-19T09:4x+08:00，标签快照落地前） | 同上 | - | - | - |
| contact_tag_cache_test（WS-B0） | 8 通过 / 0 失败（含 3 个新增快照用例） | 同上 | - | - | - |
| verify.ps1 | 第一次后台运行与并行会话提交/本任务编辑并发，结果作废已停；最终改以 analyze + 全量 flutter test 收口（见下行） | 同上 | - | - | - |
| 全量 flutter test + analyze（最终，含标签快照与并行提交） | analyze：**No issues found**（2026-09-19T10:0x+08:00，修复 3 处 lint 后）。全量：**3425 通过 / 1 失败**，唯一失败 = `redpacket/red_packet_claim_detail_page_test.dart`（并行会话 09:57 正在编辑该页的中间态，文件不在本任务所有权内；本任务改动无回归） | 同上 | - | - | - |

环境：Windows 10（win32 10.0.19045），Flutter SDK `C:\src\flutter`，pub 镜像 `pub.flutter-io.cn`（工作区代理不稳定，直连 pub.dev 报 TLS 错误时使用）。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 调查/审计（3 并行探索代理） | 2026-09-19 早 | ~09:00 | 外部等待=代理运行 | 3 组并行 | 会话记录 | - |
| 红测试 | ~09:00 | ~09:20 | - | - | 编译失败=缺口证明 | - |
| 实现 | ~09:20 | ~09:35 | 返工：架构守卫测试同步修订（旧弹窗契约） | - | 会话记录 | - |
| 定向验证 | ~09:35 | ~09:39 | 外部等待=pub 镜像 | - | 102+22 全绿 | 全量/verify.ps1 |

## 交接与回退

- 已确认根因/已排除假设：房间瘫痪根因=SDK `inner.send()` 无超时 → `Room._sendingQueue` 队首永久悬挂（已修复）；无红叹号根因=①sending 渲染成已发出+悬挂、②`StateError('消息发送失败')` 不被网络分类器识别 → 终局 failed/无自动重发（均已修复）。已排除：watchdog 只修 sync 不修发送是次因（重连本身正常，是发送队列卡死）。
- 待办及验收失败项：真机弱网/断网验收（含 20s 阈值与 `weak` 阈值标定）；媒体大文件慢链路上传 20s 窗口的真机标定（字节已落盘 `cacheOutgoingMedia`，失败自动重传）。
- 已发布与仅候选的区别：本任务全部为**未发布源码变更**，无构建无发布。
- 生产备份位置、恢复操作、漂移检查、可重试阶段：不适用（未触碰生产）。
- 运行中CI/命令/自己创建的隧道：无。
- 下次恢复先检查的事实：全量 flutter test / verify.ps1 结果是否已回填本记录；WS-B 批次（页面加载模型）是否已开始（另立任务记录，不得与本文件混写）。
