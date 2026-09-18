# 2026-09-18 Offline First：进入好友加密会话不再被网络阻塞

- 现象（用户复现）：进入聊天 A → 弱网环境退出 → 进入好友 B 资料页 → 点「发消息」→
  弹「无法打开加密会话：无法打开会话，请稍后重试」，等待后才自动进入。
- 目标：微信式 Offline First —— 点开好友会话**立即进入**，网络只影响内容同步与消息投递，不影响进入。
- 边界（用户明确）：**不改 Matrix 加密协议**；只优化 Room opening lifecycle、Network handling、
  Message retry state、UI error handling。
- 任务记录：[2026-09-18-offline-first-chat](../workflow/tasks/2026-09-18-offline-first-chat.md)

## 1. 根因（代码级确证）

打开好友会话的唯一实现是 `AppHome._openMessage` → `_resolveDirectMessageTarget`：

```dart
final authoritative = await resolveFriendContact(cache, contact);
final reference = await directChats.open(matrixUserId);   // ← 网络：业务目录 + Matrix
return DirectMessageTarget(roomId: reference.roomId, contact: authoritative);
```

`directChats.open`（`CoordinatedDirectChatGateway.openOrCreateDirectChat`）按序执行：
本地 `findCached`（本地库，未命中即“不确定”）→ **业务 API `GET /direct-conversations`（canonical）** →
命中则 `openCanonicalRoom`（`joinRoomById` 15s、`waitForRoomInSync` 15s、`waitForJoinedRoom` 12s、
`/members` + 4×300ms 健康轮询、必要时 repair）→ 未命中则 `claim`（HTTP）→ 可能 `createDirectChatOnce`
（`startDirectChat(waitForSync: true)`）→ `publish`（HTTP）→ 20×500ms 轮询 canonical。

弱网/无网时上述任一步抛出（`SocketException` / `TimeoutException` / `ClientException`），
异常的**唯一**捕获点是 `_openMessage` 的 `catch` → `showDirectChatFailureDialog`，
标题固定为「无法打开加密会话」（`direct_chat_failure.dart`），文案回落到
`networkOrOther` 的「无法打开会话，请稍后重试。」——与用户截图逐字一致。

补充事实：`RoomPage` 硬绑定 `MatrixRoomLease`，而 `MatrixRoomLease.attach` 在本地没有该 room 时
抛 `StateError('Matrix room is unavailable')`。因此“本地没有房间时也要能进入”**必须**有一个
不依赖真实 room 的 pending 页面，仅靠改导航顺序无法实现。

## 2. 改动（按用户 6 项要求）

### 2.1 打开链路：禁止网络阻塞页面进入（要求一、二）

| 文件 | 改动 |
| --- | --- |
| `lib/app_home.dart` | `_openMessage` 改为**本地优先**：`_resolveLocalDirectMessageTarget`（只读：好友目录 + SDK 本地库 + 持久化房间号提示）命中 → 走既有唯一入口 `_openManagedRoom` 立即进入；未命中 → `_openPendingConversation`（后台仲裁 + 立即进入 pending 页）。原“等待网络才导航”的 `_resolveDirectMessageTarget` 已删除 |
| `lib/features/matrix/room_opening_policy.dart` | 策略判定新增 Offline First 分支：**本地已知（房间已在本地库，即便尚未 join）→ `openNow('local_known')`，零有界等待**；仅“本地完全未知”保留一次有界等待（无 room object 无法渲染）；`requireNetwork` 来源语义不变 |
| `lib/features/matrix/direct_chat_controller.dart` | `DirectChatGateway` 新增两个**零网络、零抛错**方法：`tryLocalDirectChat`（本地安全快照）与 `localRoomHint`（协调 intent 的持久化房间号）；`DirectChatController.tryLocal/localRoomHint` 兜住任何异常返回 null；LEGACY 实现返回 null |
| `lib/features/matrix/coordinated_direct_chat.dart` | 实现上述两方法：`findCached` 命中且“加密 + 恰好两名成员且含对端”才返回；`localRoomHint` 读 intent 存储；其余情况返回 null（绝不联网、绝不抛错） |
| `lib/features/matrix/matrix_e2ee_client.dart` | `MatrixSdkE2eeClient` 实现 `tryLocalDirectChat`（只读 `findCachedDirectChat` 并做同样的安全判定）与 `localRoomHint`（返回 null） |
| `lib/features/matrix/pending_conversation_page.dart`（新） | **Pending conversation**：立即渲染好友 + 当前网络状态 + 后台建立进度；输入消息进入队列并显示「等待发送」；后台 `openRoom()` 就绪 → `pop(PendingConversationResult(roomId, queued))`；失败 → 按分类内联文案 + 「重试」。不做任何网络读写，不构造 RoomPage（架构守卫保持） |
| `lib/features/matrix/room_navigation_coordinator.dart` | `RoomOpenRequest` 新增只承载数据的 `outbox`（pending 期间排队文本），供唯一入口传给 RoomPage |
| `lib/features/matrix/room_page.dart` | 新增 `initialOutbox`：首次加载完成后按顺序自动发送排队消息（走既有 `sendText`，不自行等待网络） |
| `lib/features/matrix/direct_chat_entry.dart` | `DirectMessageOpenGate` 结果类型放宽为可空（“本地还没有会话”是正常结果，不是失败），单飞语义不变 |

### 2.2 统一网络状态（要求四）

- 新文件 `lib/core/network_state_manager.dart`：`enum NetworkState { online, weak, offline, recovering }`，
  `ValueNotifier` 驱动、只在变更时通知；`report/reportFailure/reportSuccess/whenOnline/reset/dispose`；
  恢复等待**不创建定时器**；不依赖 Matrix/HTTP/connectivity_plus。
- 组合根接线（`app_home.dart::_bindNetworkState`）：复用既有 `MatrixSyncWatchdog.connectionStatus`
  （它已合并 connectivity_plus 传输态 + SDK sync 状态 + 重连序列）投影为四态，会话进入（pending 页状态文案）
  与消息发送（子任务的自动重试）共用同一真相源。关闭时移除监听。

### 2.3 错误提示（要求五）

`direct_chat_failure.dart` 改为按类型出标题与文案，**删除**「无法打开加密会话」口径：

| 类型 | 触发 | 标题 | 正文 |
| --- | --- | --- | --- |
| offline | `SocketException` / `http.ClientException` | 当前没有网络 | 当前没有网络，消息将在恢复后同步。 |
| weak | `TimeoutException`（及未分类） | 网络不稳定 | 网络不稳定，请稍候。 |
| server | HTTP 5xx / 服务不可用 | 服务器连接失败 | 服务器连接失败，请稍后重试。 |
| crypto | 成员/加密未就绪、登记未完成、房间不可用 | 安全会话初始化失败 | 安全会话初始化失败，请稍后重试。 |
| 其余 | 好友已删 / 401 / 403 / 同步中 | 保持既有专用文案 | 不提供无意义重试 |

### 2.4 消息发送状态（要求三）

`RoomDeliveryState` 扩展为 `{ local, sending, waitingNetwork, failed, sent }`（`room_timeline_controller.dart`）：

- 新建的乐观行是 `local`，`_dispatch` 开始时同步翻成 `sending`（内部转换不额外 notify，保持既有性能契约测试
  “SDK burst publishes once per frame” 不退化）；
- 失败分流：`defaultNetworkFailureClassifier` 判为**网络类**（Socket/Timeout/ClientException/5xx）→
  `waitingNetwork`，并把错误上报 `NetworkStateManager.reportFailure`；服务端拒绝、权限/互动门等 → 仍为 `failed`；
- **恢复自动重发**：首次网络失败时懒挂一个 `ValueListenable` 监听，`NetworkStateManager` 变为
  `online`/`recovering` 时把**所有** `waitingNetwork` 行按**原 txid** 重发（`_retrying` +
  `_drainingWaitingNetwork` 幂等、`dispose` 解绑、无定时器、无轮询）；
- 手动 `retry(txid)` 同时覆盖 `failed` 与 `waitingNetwork`；
- 呈现（`wechat_message_bubble.dart` / `room_page.dart`）：`MessageDeliveryState` 增加 `waitingNetwork`，
  渲染小时钟 + 「等待发送」（key `message-delivery-waiting`，点击即重试），**红色感叹号只用于 `failed`**。
- 组合根接线：`app_home.dart::_bindNetworkState` 已 `NetworkStateManager.shared ??= NetworkStateManager()`
  并投影 `MatrixSyncWatchdog.connectionStatus`（offline→`transportAvailable:false`，
  connecting→`recovering`，connected→`serverReachable:true`），因此生产环境恢复事件可达。

## 3. 测试（要求六）

| 验收 | 测试 | 结果 |
| --- | --- | --- |
| 无网络进入好友聊天 → 可以进入 | `test/features/matrix/offline_first_opening_test.dart`：本地命中零网络；本地缺失返回 null 不抛错；pending 页首帧即渲染并在无网时给出“消息将在恢复后同步”；后台就绪后回传 roomId + 排队消息 | **+9 全通过** |
| 弱网进入好友聊天 → 不阻塞导航 | 同上 + `room_opening_policy_test.dart`：本地已知（未 join）→ `openNow` 且 `awaitLocalRoom` 未被调用；本地完全未知 → 仍有界等待一次 | 全通过 |
| 弱网发送消息 → 显示等待发送 | `test/features/matrix/offline_send_state_test.dart`（12 条：网络失败→`waitingNetwork` 且呈现「等待发送」；服务端/权限失败仍 `failed`；手动重试；恢复后按原 txid 自动重发；重复恢复不双发） | **12 全通过** |
| 恢复网络 → 自动发送成功 | 同上 + `test/core/network_state_manager_test.dart`（25 条：offline/weak/recovering 迁移、`whenOnline` 多等待者不建定时器、dispose 后安全） | 25 全通过 |
| 发送状态机回归 | `optimistic_timeline_test` / `room_send_identity_regression_test` / `matrix_room_timeline_adapter_test` / `wechat_components_test` 等 5 文件 **+58 全通过**；另 15 文件 **+155 全通过** | 全通过 |
| 不改加密协议 | 未触碰 SDK fork / Olm / Megolm / 密钥 / 建房协议；变更文件全部属于打开生命周期、网络、消息状态与文案 | 架构守卫套件（`room_opening_policy_test.dart` Test 1/2/8）全通过 |

### 3.1 契约变更（有意为之，已同步测试）

1. `RoomOpeningPolicy`：本地**已知但未加入**的房间从「一次有界等待」改为**立即打开**（`local_known`）。
   理由：产品要求“禁止网络请求阻塞页面进入”，且房间已在本地库即可渲染（roomInfo/时间线来自本地 DB），
   成员与加密状态由页面后台刷新。对应测试 `本地未加入（仅已知）→ 立即打开，不再等一次网络同步`。
2. `DirectChatGateway` 新增两个方法：所有实现（生产网关、LEGACY 网关、`MatrixSdkE2eeClient`）与
   测试假实现同步补齐。
3. `DirectMessageOpenGate` 结果可空：`direct_chat_entry_test.dart` 相应更新（3 处闭包签名 + 6 处非空断言）。
4. 发送状态机：`video_send_limit_test.dart` 有 1 处断言由 `failed` 改为 `waitingNetwork`
   （该用例的首发失败是 `SocketException('offline')`，按新语义属于“等待网络”而非硬失败；其后的手动重试仍断言
   发满 2 次并最终 `sent`）。其余既有 `failed` 断言使用的是 `StateError` 或互动门，语义未变，**未**改动。

## 4. 门禁结果与“非本任务”失败的责任范围

| 门禁 | 命令 | 结果 |
| --- | --- | --- |
| 静态分析 | `flutter analyze lib test` | **No issues found** |
| 本任务新增测试 | `flutter test test/features/matrix/offline_first_opening_test.dart test/features/matrix/offline_send_state_test.dart test/core/network_state_manager_test.dart` | 9 + 12 + 25 = **46 全通过** |
| 受影响既有套件 | policy / failure / entry / lifecycle / controller / coordinated / cached-local / profile-wiring / call-entry / contacts-identity / optimistic-timeline / send-identity / adapter / components | 全通过（详见上文分项） |
| 全量 Flutter | `flutter test --timeout 120s` | **`+3221: All tests passed!`**（改动前 3173；本任务新增/净增 48 条） |
| 移动边界门禁 | `pytest tests/mobile -q` | **68 passed / 1 失败且非本任务**（见下） |
| 仓库整体门禁 | `scripts/verify.ps1` | 未重跑（本任务只改 Flutter 客户端；服务端/仓库部分未受影响），已用上述子集替代 |

**非本任务的失败（如实记录，未修）**：`pytest tests/mobile/test_android_ci_workflow.py::test_android_ci_workflow_exists_and_pins_flutter`
断言工作流里存在字面量 `run: flutter test`，而同日另一会话的提交 `bd28dbff`
（`ci(flutter): diagnose the real failing test instead of guessing from log noise`）把该行改成了
多行脚本里的 `flutter test 2>&1 | tee "$log"`。该守卫测试自 `f518dc7c` 起未变、本任务未触碰
`.github/workflows/**`，因此责任属于该提交。修复方式二选一（归该会话）：恢复单行 `run: flutter test`，
或让守卫接受“脚本内含 flutter test”的写法。

### 4.1 全量 Flutter 测试

`flutter test --timeout 120s` → **`+3221: All tests passed!`**（2 分 38 秒；退出码 0）。
本任务新增 46 条（打开 9 + 发送状态 12 + 网络状态 25），其余净增来自新增页面的组件/守卫用例。

## 5. 未完成 / 已知限制（如实记录）

- **pending 队列仅内存**：进程被杀后排队消息丢失（房间号提示持久化在 intent，但未发送文本未落盘）。
  下一步可加一个按 account+peer 键控的持久化 outbox。
- **未做真机验收**：A1–A4 均为单元/组件级证据，等真机（弱网/飞行模式）确认。
- **`NetworkStateManager` 只接了 Matrix 看门狗信号**：业务 API 的 `BusinessSessionRestore.offline`
  尚未喂入；`weak` 阈值默认为 2 秒往返，未在真机标定。
- **未构建、未发布**：本任务只改客户端逻辑；是否出包由用户决定。
