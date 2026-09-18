# ChatFlow Room Opening Policy Engine

**从 Single Room Opening Architecture 到 Single Room Opening Platform**

- **日期**：2026-09-18
- **范围**：`apps/mobile_flutter`（唯一生产 Flutter 客户端）
- **前置**：[会话打开架构审计](room-opening-architecture-audit.md)（结论：页面打开已统一，但
  `RoomNavigationCoordinator` 只是 **Navigation Coordinator**，不是 **Room Opening Policy Engine**）
- **本次新增/改动**：`RoomOpeningPolicy`、`RoomOpenMode`、`RoomOpenSource`、`RoomOpenFailure`、
  `RoomVisibilityPolicy`、统一失败反馈；三个 Tab 的搜索注入一致；控制房间过滤统一
- **未改动**（明确约束）：`RoomPage` 创建逻辑、`RoomLease` 生命周期、
  `DirectChatController`、`CoordinatedDirectChatGateway`、Matrix 协议、E2EE、Media Engine，
  以及 `RoomNavigationCoordinator` 的**导航职责**（去重/复用/`popUntil`/登记清理）

---

## 1. Before → After

### 1.1 改造前（审计发现的形态）

```
入口
 │
 ├─ 消息列表 ──► RoomNavigationCoordinator ──► RoomPage      ✅ 统一
 ├─ 好友资料 ──► RoomNavigationCoordinator ──► RoomPage      ✅ 统一
 ├─ 通知/Push ─► waitForRoom(≤10s) ─ catch(_){} ─► 无反应    ❌ 先等网络 + 静默失败
 ├─ 搜索 ─────► waitForJoinedRoom(≤12s) ─ catch(_){} ─► 无反应 ❌ 先等同步 + 静默失败
 ├─ 通讯录搜索 ► onOpenRoom == null ─► 群聊/聊天记录分组不渲染  ❌ 能力分叉
 └─ 发现搜索 ──► onOpenRoom == null ─► 同上                    ❌ 能力分叉

控制房间过滤：消息列表 build 内按**展示名白名单**过滤；搜索页**完全没有**过滤
```

具体问题（对应审计 P1-1 / P1-2 / P1-3 / P2-1）：

| 问题 | 表现 |
| --- | --- |
| 打开前策略散落在各入口 | 每个入口自己写 `waitForRoom` / `waitForJoinedRoom` / `catch (_) {}` |
| 离线无法打开已有会话 | 通知/搜索在离线时最长等 10–12 秒后**静默放弃** |
| 失败不可见 | `catch (_) {}` 吞掉异常，用户看到"点了没反应" |
| 入口能力分叉 | 同一个 `GlobalSearchPage` 在 3 个 Tab 有 3 种行为 |
| 控制房间判定靠名字 | `'畅聊表情仓库'` / `'畅聊提醒同步'` 硬编码，改名失效、同名误判，且只有列表用了它 |

### 1.2 改造后（目标形态）

```
入口
 │   （每个入口只声明"我是谁"：RoomOpenSource）
 ▼
RoomOpenRequest { roomId, anchorEventId?, source, mode?, onRoomReady?, onRoomClosed? }
 │
 ▼
RoomOpeningPolicy                          ◄── RoomOpenLocalProbe（本地只读事实）
 │  1. 可见性判定（RoomVisibilityPolicy：roomId + accountData，不用名字）
 │  2. 离线优先判定（本地已 joined → 立即放行，**零网络等待**）
 │  3. 网络姿态判定（offlineFirst / localThenNetwork / requireNetwork）
 │  4. 有界网络等待（仅在"本地没有这个房间"时；等待函数由组合根注入）
 │  5. 失败分类（RoomOpenFailure：offline/networkUnavailable/permissionDenied/
 │     roomNotFound/notJoined/temporaryFailure）
 ▼
RoomNavigationCoordinator                  ◄── 职责完全不变
 │  同一 roomId 单实例 / 并发合并 / popUntil 复用 / 登记清理
 ▼
RoomPage（唯一创建点）+ MatrixRoomLease（唯一租约所有者）
 │
 ▼
统一失败反馈：showRoomOpenFailureDialog（唯一致用户可见文案来源）
```

**一句话**：协调器仍然只管"怎么导航"，策略层负责"能不能开、要不要等、等多久、失败了怎么说"。

---

## 2. RoomOpenRequest 扩展

`features/matrix/room_navigation_coordinator.dart`（仅扩展请求模型，导航逻辑未改）

```dart
RoomOpenRequest {
  String  roomId;              // 唯一键（群聊/私聊都用 roomId）
  String  roomName;            // 展示名（空 → 打开流程向本机会话目录取）
  ContactDetails? initialContact;
  String? anchorEventId;       // 正式 anchor 契约（搜索/深链定位）
  RoomOpenSource source;       // 打开来源（诊断 + 默认网络策略）
  RoomOpenMode? modeOverride;  // 仅确有例外时覆盖
  RoomOpenMode get mode => modeOverride ?? source.defaultMode;
  void Function()? onRoomReady;   // 租约已取、页面未 push
  void Function()? onRoomClosed;  // 页面退出/打开失败后收尾
}
```

`source` 的**全部**取值（含默认网络姿态）：

| source | wire name | defaultMode | 说明 |
| --- | --- | --- | --- |
| `conversationList` | `conversation_list` | `offlineFirst` | 消息列表点击会话 |
| `search` | `search` | `offlineFirst` | 本机历史搜索命中（群聊/聊天记录 + anchor） |
| `contactProfile` | `contact_profile` | `offlineFirst` | 好友资料/群成员资料「发消息」 |
| `groupAddressList` | `group_address_list` | `offlineFirst` | 通讯录 → 群聊通讯录 |
| `groupCreated` | `group_created` | `offlineFirst` | 建群成功进入新群 |
| `notification` | `notification` | `localThenNetwork` | 系统通知 / 推送 / 应用内横幅 |
| `friendAccept` | `friend_accept` | `localThenNetwork` | 好友通过后进入会话 |
| `scan` | `scan` | `requireNetwork` | 扫码入群后进入群聊 |
| `unknown` | `unknown` | `localThenNetwork` | 兜底（禁止新增生产调用） |

来源是**诊断**用途：每次打开会写一条
`[room-open] source=… mode=… outcome=… reason=… room=…`（只含房间号与枚举，不含消息内容）。

---

## 3. Policy Rules

### 3.1 判定顺序（`RoomOpeningPolicy.evaluate`，纯函数、无 I/O）

| # | 条件 | 判定 | reason |
| --- | --- | --- | --- |
| 1 | `roomId` 为空 | deny `roomNotFound` | `empty_room_id` |
| 2 | 不可见（控制房间，accountData 引用） | deny `roomNotFound`（fail-closed，不泄露内部房间存在性） | `hidden_control_room` |
| 3 | 本地已 joined | **openNow** | `local_joined` |
| 4 | 本地已知但未 joined + `requireNetwork` | deny `notJoined` | `local_not_joined` |
| 5 | 本地未知 + `requireNetwork` | deny `notJoined` | `local_missing_requires_network` |
| 6 | 本地已知但未 joined + 其余模式 | awaitLocalRoom | `local_not_joined` |
| 7 | 本地未知 + `offlineFirst` / `localThenNetwork` | awaitLocalRoom | `local_missing` |

**铁律**：第 3 条对三种模式一致——**本地已加入的房间永远不等待网络**。
"只有本地不存在，才允许 network fallback"。

### 3.2 网络姿态（`RoomOpenMode`）

| mode | 语义 | 用于 |
| --- | --- | --- |
| `offlineFirst` | 本地命中零等待；本地缺失才做有界回退 | 消息列表、搜索、好友私聊、群聊通讯录、建群后 |
| `localThenNetwork` | 本地命中零等待；本地缺失时**预期**要等一次（冷启动） | 通知/推送/横幅、好友通过 |
| `requireNetwork` | 前置步骤（入群）本应完成；本地缺失即拒绝，不做静默等待 | 扫码入群 |

### 3.3 与任务书 §5 网络策略的逐条对应

| 任务书要求 | 实现落点 |
| --- | --- |
| 消息列表 → `offlineFirst` | `RoomOpenSource.conversationList.defaultMode` |
| 搜索聊天记录 → `offlineFirst` | `RoomOpenSource.search.defaultMode` |
| 通知 → `localThenNetwork` | `RoomOpenSource.notification.defaultMode`（推送/横幅同源） |
| 已有好友私聊 → `offlineFirst` | `RoomOpenSource.contactProfile.defaultMode`（`findCachedDirectChat` 本地命中即开） |
| 第一次创建私聊 → `requireNetwork` | **由 `CoordinatedDirectChatGateway` 承担**（`canonicalRoomId`/`claim`/`createOnce` 本身必须联网）。它不是"打开房间"，因此不经过 `RoomOpenRequest`；一旦房间存在，**打开**这个房间仍走 `offlineFirst` |
| 扫码入群 → `requireNetwork` | `RoomOpenSource.scan.defaultMode`（入群已完成，房间不在本地即明确失败，不静默等待） |

### 3.4 职责边界

| 属于 `RoomOpeningPolicy` | 不属于（仍归协调器/组合根） |
| --- | --- |
| 可见性/可打开性判定 | 页面创建（`RoomPage`） |
| 网络姿态与有界等待编排 | 租约获取/释放/revoke |
| 失败分类与用户文案 | `Navigator` push / `popUntil` / 去重登记 |
| 诊断事件（来源/模式/结果） | 已读未读、列表快照刷新（调用方 `onRoomReady/onRoomClosed`） |

---

## 4. Offline Strategy

### 4.1 探针：只读本机事实（零网络）

`RoomOpenLocalProbe`（生产实现 `_MatrixRoomOpenProbe` → `MatrixSdkE2eeClient`）：

```dart
bool knowsRoom(String roomId);      // 本机 SDK store 已知该房间
bool isJoined(String roomId);       // 本机 SDK store 中已加入
Set<String> get controlRoomIds;     // accountData 引用的控制房间
```

实现只调用 `client.getRoomById(...)` 与 `client.accountData[...]`，
**绝不**触发 `/sync`、`waitForRoomInSync`、`/members`。这是"离线可开"的前提。

### 4.2 各入口的离线行为（改造后）

| 入口 | 改造前 | 改造后 |
| --- | --- | --- |
| 消息列表 | 本地打开（无网络依赖） | 不变（新增 `source` 诊断） |
| 搜索（群聊/聊天记录） | **先等 `waitForJoinedRoom`（≤12s），离线静默失败** | 本地列表命中 → **立即打开**；未命中 → 策略有界等待 + 可见失败 |
| 通知/推送/横幅 | **先等 `waitForRoom`（≤10s），离线静默失败** | 本地已 joined → **零等待打开**；未命中 → 有界等待 + 可见失败 |
| 好友资料「发消息」 | 有本地快路径（`findCachedDirectChat`），慢路径含网络 | 不变（打开阶段策略放行本地房间） |
| 通讯录群聊列表 | 本地打开 | 不变 |
| 建群成功 | 本地打开 | 不变 |
| 扫码入群 | 业务需网络 | `requireNetwork`：本地缺失即明确失败，不静默等待 |
| 好友通过 | 业务需网络 | `localThenNetwork`：本地命中即开 |

### 4.3 有界等待

`AppHome._awaitLocalRoom` → `matrix.waitForRoom(roomId).timeout(12s)`；
返回 `false` 表示"窗口内没等到"，由策略统一转成
`RoomOpenFailureKind.temporaryFailure` → **"无法打开会话，请检查网络"**。
等待**只在本地没有该房间时**发生，且**失败一定可见**。

---

## 5. Error Model

### 5.1 失败分类（唯一模型）

```dart
enum RoomOpenFailureKind {
  offline,            // 网络不可用，请稍后重试
  networkUnavailable, // 网络不可用，请稍后重试
  permissionDenied,   // 无法打开该会话
  roomNotFound,       // 会话不存在或已被删除
  notJoined,          // 尚未加入该会话，请稍后重试
  temporaryFailure,   // 无法打开会话，请检查网络
}
```

`RoomOpenFailure` 携带 `kind / roomId / source / cause`，并暴露：

- `userMessage`：**唯一**允许展示的文案来源（不含房间内容、成员、消息）；
- `isRetryable`：`offline` / `networkUnavailable` / `temporaryFailure` **以及 `notJoined`**
  可重试。`notJoined` 最常见的成因是"刚入群，本地还没同步到"，几秒后重试通常即成功；
  早期版本把它判为不可重试 + 对话框只有「知道了」，扫码入群后会变成死胡同。

异常映射（`RoomOpeningPolicy.classify`）：`TimeoutException` → `networkUnavailable`；
`SocketException` / `HttpException` → `offline`；`StateError('…unavailable')` → `roomNotFound`；
其余 → `temporaryFailure`。**本地打开失败（例如租约取不到房间）同样被分类为可见失败**。

### 5.2 禁止静默 + 反馈契约

- 通知/推送/横幅路径的 `catch (_) {}` 已删除（守卫测试断言该代码段不再包含它）；
- 所有入口经 `AppHome._openManagedRoomRequest` → 失败统一进入
  `showRoomOpenFailureDialog`（`Key('room-open-failure')`，标题「无法打开会话」，正文 `userMessage`）；
- **可重试**失败（`failure.isRetryable`）多给一个「重试」按钮，对话框返回 `true` 时
  组合根用**同一个 `RoomOpenRequest`** 重跑（幂等：协调器去重 + 网关不会重复建房）；
  不可重试失败只给「知道了」，不引导无意义重试；
- 反馈是 **single-flight** 的（`_roomOpenFailureVisible`）：对话框存在期间的再次打开请求
  直接忽略，用户连点或"推送 + 点击"同时到达不会叠出多层对话框；
- 搜索/群聊通讯录/建群/好友通过等路径不再各自 `catch`，失败一律冒泡到同一反馈点；
- 「通知已打开」埋点移到 `onRoomReady`：**只有真的进到房间才计数**，失败不会留下虚假统计。

### 5.3 等待上限与可见进度

| 项 | 改造前 | 现在 |
| --- | --- | --- |
| 等待上限 | 10s（通知）/ 12s（搜索） | **5s**（`_roomOpenWaitTimeout`，只在"本地没有该房间"时发生） |
| 等待期间反馈 | 无（纯静默空等） | 根 Overlay 上的转圈（`Key('room-open-waiting')`，与消息列表同一做法，避免低端机上 modal 与 push 的同帧竞争） |
| 超时结果 | `catch (_) {}` 静默放弃 | 可重试的 `temporaryFailure` + 「无法打开会话，请检查网络」+「重试」 |

---

## 6. RoomVisibilityPolicy（控制房间统一过滤）

### 6.1 判定来源（禁止名字）

| 事实 | 来源 |
| --- | --- |
| 控制房间 roomId | ① accountData `com.changliao.emoji.vault`.room_id、`com.changliao.reminders.control`.room_id（账号级权威身份）；② **本会话创建登记** `ControlRoomRegistry`（补 accountData 可读前的窗口） |
| 被判定房间 | 打开/展示时的 `roomId` |

`RoomVisibilityPolicy.forRoomIds([...])` 是**纯值对象**：
`isVisible` / `isOpenable` / `isControlRoom`，`merge` 支持多来源合并。

### 6.2 三处使用同一规则

| 使用点 | 之前 | 现在 |
| --- | --- | --- |
| 消息列表 build | `isMatrixControlRoom(displayName: …)` 名字白名单 | `RoomVisibilityPolicy.forRoomIds([vault, reminder]).isVisible(room.id)` |
| 全局搜索 `_loadRooms` | **无过滤**（控制房间可被搜索并打开） | 同一策略过滤（注入的 `roomsLoader` 也走同一过滤） |
| 转发目标列表 | 名字白名单 | 同一策略（`roomVisibilityFromAccountData(client)`） |
| **打开判定** | 无（依赖列表已过滤） | `RoomOpeningPolicy` 第 2 条 fail-closed：控制房间`roomNotFound` |

`matrix_control_rooms.dart` 现在是**唯一解析点**：
`roomVisibilityFromAccountData(Client)` → `RoomVisibilityPolicy`，名字白名单已删除
（守卫测试断言这四个文件的可执行代码里不再出现那两个展示名）。

### 6.3 创建即登记（关闭 accountData 窗口）

`ControlRoomRegistry`（`control_room_registry.dart`，只依赖 `foundation`，避免循环依赖）：

| 时机 | 动作 |
| --- | --- |
| 新建表情仓库房间（`createEncryptedVaultRoom`） | `ControlRoomRegistry.register(roomId)` |
| 复用或新建提醒同步房间（`MatrixMessageReminderBackend.open`） | `ControlRoomRegistry.register(...)`（accountData 缺失时也先登记） |
| 登出 / 清空本地数据（`clearLocalChatData`） | `ControlRoomRegistry.clear()`（账号级资源不跨账号累积） |

这样即便 `accountData` 尚未对本机可读（刚创建/刚登录/刚切换账号），该房间也**不会**
出现在列表或搜索结果里，也**不会**被任何入口打开；判定依然只看身份（roomId /
accountData / 会话登记），不看展示名，也不修改任何 Matrix 协议或房间状态。

---

## 7. Tests

### 7.1 新增：`test/features/matrix/room_opening_policy_test.dart`（任务书 §12 的 7 条）

| Test | 内容 | 断言要点 |
| --- | --- | --- |
| **1** | RoomPage 创建点仍只有 1 处 | 扫描 `lib/**` 中 `=> RoomPage(` / `RoomPage(…api:` 的构造点集合 == `['lib/app_home.dart']` |
| **2** | 所有入口必须经过 `RoomOpeningPolicy` | 组合根出现 `RoomOpeningPolicy(` / `_roomOpening.open(` / `probe:`；**所有** `RoomOpenRequest(` 都带 `source:`；通知路径无 `catch (_) {}` 且经 `_openManagedRoomRequest`；`_openRoomById` 不含 `waitForJoinedRoom`；三个 Tab 的搜索都注入 `onOpenRoom`（非 optional） |
| **3** | 离线：消息列表打开成功 | 本地已 joined → `navigate` 调用 1 次，`awaitLocalRoom` **0 次**；reason == `local_joined` |
| **4** | 离线：通知打开已有房间成功 | `localThenNetwork` + 本地命中 → 零等待；本地未知 → 有界等待 1 次；等待超时 → `temporaryFailure` 且文案 = 「无法打开会话，请检查网络」 |
| **5** | 离线：搜索历史消息打开成功 | `offlineFirst` + 本地命中 → 零等待且 **anchor 保留**；仅"本地已知未加入"才允许一次网络回退 |
| **6** | 网络失败：显示错误，不能 silent | 每个失败分类都有非空且不含房间号的文案；widget 测试真实弹出统一对话框并显示「网络不可用，请稍后重试」；本地打开失败（`StateError('Matrix room is unavailable')`）也被分类为 `roomNotFound` |
| **7** | 控制房间：搜索不可见 | 注入 `visibility` 后 widget 测试：控制房间不渲染、普通群聊可见且点击回调收到正确 roomId；另有 `matrix_control_rooms_test.dart` 的纯策略/反硬编码守卫 |
| **8** | 架构债守卫（审计 B 组） | ① 控制房间身份只来自 roomId/accountData/会话登记，且创建方都登记、登出清理；② legacy 私聊创建面（`DirectChatService` / `CanonicalDirectChatGateway` / 客户端 `.openOrCreateDirectChat`）不得被生产代码调用；③ 好友通过生产接线必须传 `onEstablishDirectChatWithRequest`，旧回退标注 `@visibleForTesting`；④ `RoomPage` 不再维护 `StatisticsRoomScope`，改由打开流程 enter/leave；⑤ 失败反馈 single-flight + 可重试 + 等待上限 5s + 可见进度 |
| **6 增补** | 重试语义 | `notJoined` 可重试；可重试失败弹出「重试」并回传 `true`；不可重试只有「知道了」 |

### 7.2 更新（架构变更导致的既有守卫）

| 文件 | 变更 |
| --- | --- |
| `profile_message_route_wiring_test.dart` | 「AppHome 通过策略层 + 协调器」：断言 `RoomOpeningPolicy(` / `_roomOpening.open(` / `navigate: _roomNavigation.open` / `RoomOpenSource.groupCreated` |
| `global_search_page_test.dart` | `onOpenRoom` 必填（`nav == null` → no-op）；原「无导航能力时不展示分组」改为「分组恒可用，能力不分叉」 |
| `matrix_control_rooms_test.dart` | 从"名字白名单"改为"accountData/roomId 驱动" + 反硬编码守卫 + **创建即登记**守卫 |
| `account_client_selection_test.dart` | 图库批处理用例的等待从"一个微任务轮次"改为**有界轮询**（见 §7.4） |
| 8 个测试文件的 `ContactsPage` / `ContactsTabPage` / `DiscoveryPage` / `GlobalSearchPage` 构造点 | 注入 `onOpenRoom`（必填参数） |

### 7.4 flake 根因与修复（`account_client_selection_test`）

- **现象**：全量并行下偶发失败（"9 个延迟图库视频在一个准备预算内"）；隔离运行与重跑均通过。
- **根因**：用例在 `enqueueVideoFiles` 之后只等**一个** `Future.delayed(Duration.zero)` 就断言
  `started == [0]`；而 `_enqueueVideoFiles` 在第一个 `prepare` 之前还有真实文件 I/O
  （`await video._waitForSourceMetadata()`）。并行负载下这一个事件循环轮次不足以完成 I/O，
  `started` 仍为空 → 断言失败。**这是测试的时序假设问题，不是产品缺陷。**
- **修复**：改为有界轮询 `_pumpUntil(...)`（默认 10s 上限、超时给出明确原因）。
  断言语义**不变且更强**：仍是"同一时刻只允许一个 gallery handle 准备"，
  且每次都等到下一个准备真正开始后再校验预算，而不是落在空窗里。
- **为何不"重试掩盖"**：没有引入 retry/skip，只是把"时序假设"换成"有界等待不变量"。

### 7.3 实测结果

| 范围 | 命令 | 结果 |
| --- | --- | --- |
| 静态分析（含测试） | `flutter analyze` | **No issues found!**（19.4s） |
| 受影响套件（策略/控制房间/flake/作用域/协调器链） | `flutter test test/features/matrix/room_opening_policy_test.dart test/features/matrix/matrix_control_rooms_test.dart test/features/matrix/account_client_selection_test.dart test/statistics_tool_test.dart test/features/matrix/matrix_home_room_delegation_test.dart test/features/matrix/direct_message_open_lifecycle_test.dart test/features/matrix/room_navigation_coordinator_test.dart test/features/matrix/profile_message_route_wiring_test.dart` | **80 passed / 0 failed** |
| 全量测试 | `flutter test --timeout 120s` | **3170 passed / 0 failed**（exit 0；较上轮 +9 条新测试） |
| 仓库门禁 | `pwsh -NoProfile -File scripts/verify.ps1` | **`Verification: PASS`**（exit 0，含 `tests/mobile`、business-api/worker、Alembic、OpenAPI、Compose render） |

---

## 8. 兼容性与边界

| 项 | 说明 |
| --- | --- |
| `RoomNavigationCoordinator` | 行为逐字未变（去重/合并/`popUntil`/清理）；只新增了 `RoomOpenSource`/`RoomOpenMode` 与请求字段 |
| `RoomPage` / `RoomLease` | 创建点仍为 1、租约所有者仍为 `_openManagedRoomRoute`，未改生命周期 |
| `DirectChatController` / `CoordinatedDirectChatGateway` | 未改；「发消息」只是把打开阶段交给策略 |
| Matrix / E2EE / Media Engine | 未改（新增的本地读取 API 只读本机 SDK store 与 accountData；控制房间登记不改任何房间状态或协议） |
| 控制房间账号数据尚未同步的窗口 | **已由"创建即登记"覆盖**（§6.3）。仍未覆盖的极端情况：本机既没有 accountData 引用、也不是本进程创建的房间（例如另一台设备创建、本机 accountData 又被清空）——此时该房间会按普通群聊处理（这是"不用展示名"的已记录取舍） |
| 通知「已打开」埋点 | 语义更严格：只有真正进入房间（`onRoomReady`）才计数 |
| `StatisticsRoomScope` | 改由打开流程 enter/leave（`RoomPage` 不再维护）；作用域栈语义与既有单测不变 |

---

## 9. 门禁记录

| 步骤 | 命令 | 结果 |
| --- | --- | --- |
| 1 | `flutter analyze`（`apps/mobile_flutter`） | **No issues found!**（exit 0） |
| 2 | 受影响套件（见 §7.3 命令） | **80 passed / 0 failed**（exit 0） |
| 3 | `flutter test --timeout 120s`（全量） | **3170 passed / 0 failed**（exit 0） |
| 4 | `pwsh -NoProfile -File tests/repository/Test-RepositoryPolicy.ps1` | `Repository policy: PASS` |
| 5 | `pwsh -NoProfile -File scripts/verify.ps1`（仓库整体门禁） | **`Verification: PASS`**（exit 0） |

第 5 步覆盖：Repository policy、Deployment policy、Template unit tests、Render-only
configuration smoke test、Infra render tests、`Alembic migrations: PASS`（链路含 `0069_media_platform`）、
`OpenAPI contract: PASS`、business-api / business-worker、`tests/mobile`（Flutter 边界）、
`Docker Compose render`。

---

## 9.1 仓库卫生与流程（同批处理）

| # | 问题 | 处置 |
| --- | --- | --- |
| 1 | 仓库根目录存在 5 个被 git 跟踪的临时产物（`tmp_remote_*.py|plist`、`tmp_download_page.html`），违反 `AGENTS.md`「根目录不得存放临时/验证产物」 | `git mv` 到 `scripts/one-off/`（4 个运维脚本 + 说明 README）与 `docs/verification/artifacts/2026-09-18/landing-page-snapshot.html`；全仓无引用，模式扫描未发现真实密钥 |
| 2 | `.gitattributes` 只有 `*.sh eol=lf`，Windows（`core.autocrlf=true`）下每次操作都刷 CRLF 警告，多 agent 并行易产生整文件 diff | 增加 `*.dart text eol=lf`、`*.md text eol=lf`；验证未触发任何批量重写（改动后 `git status` 仍只有本次编辑的文件） |
| 3 | 上一轮审计报告的 P0-1（工作树 3 个编译错误）已过时 | 在审计报告 §9 与基线说明处标注"快照 + 已由并行批次解决"，避免被当成当前事实 |
| 4 | 提交粒度：本次推送的 `b641fe15` 同时包含并行批次与策略层 | 记录在 `docs/workflow/current-state.md`：同文件承载两块改动，按文件拆分会产生编译不过的中间态；若必须拆分需按 hunk 重做且建议新开分支而非改写 `main` |

---

## 10. 验收对照

| 验收项 | 结论 | 证据 |
| --- | --- | --- |
| `RoomNavigationCoordinator` 职责不变 | ✅ | §8；协调器测试 11 条全绿 |
| 新增 `RoomOpeningPolicy` | ✅ | `features/matrix/room_opening_policy.dart` |
| 所有入口策略统一 | ✅ | 5 条打开路径全部经 `_openManagedRoomRequest` → 策略；守卫 Test 2 |
| Offline First 覆盖已有房间 | ✅ | 策略铁律 + Test 3/4/5（本地命中零网络等待） |
| 通知不再静默失败 | ✅ | `catch (_) {}` 删除 + 统一对话框；Test 4/6 |
| 搜索行为一致 | ✅ | `onOpenRoom` 必填，三 Tab 同一回调；Test 2/7 |
| 控制房间过滤统一 | ✅ | `RoomVisibilityPolicy`（accountData + roomId）；Test 7 + 反硬编码守卫 |
| 全量测试通过 | ✅ | §9：`flutter analyze` 无问题、相关 77 passed、全量 3161 passed、`scripts/verify.ps1` = `Verification: PASS` |
