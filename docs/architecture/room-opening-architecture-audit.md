# ChatFlow Room Opening Architecture Audit Report

**会话打开架构审计报告 — 是否真正实现 Single Room Opening Architecture**

- **类型**：只读架构审计（**未修改任何 Dart / Flutter / Matrix / RoomPage / RoomLease / Navigator / DirectChatController / Media Engine 代码**）
- **日期**：2026-09-18
- **审计对象**：`apps/mobile_flutter`（唯一生产 Flutter 客户端）
- **代码基线（证据身份）**：`HEAD = 61b29917`（`docs(media): add Media Engine Phase 4 implementation report`）+ **未提交工作树**（26 个已修改文件，`git status --porcelain`）。工作树相对 HEAD 的改动**不触及**房间打开链路（`app_home.dart` 改动为拉黑名单投影、`room_page.dart` 改动为发送权限门），但存在 3 个**编译错误**（见 P0-1）。
- **前置输入**：
  - `docs/architecture/media-engine-phase3-freeze.md`（ADR-001…ADR-006 冻结边界）
  - `docs/verification/media-engine-phase4-implementation.md`（Phase 4 服务端实现报告）
- **已完成的改造（被审计对象）**：`DirectMessageOpenGate` 生命周期修复、`RoomNavigationCoordinator`、`DirectChatController` 统一私聊入口、`CoordinatedDirectChatGateway`、Media Engine Phase 4。

---

## 1. Executive Summary

### 1.1 结论一句话

**页面层面：ChatFlow 已经实现 Single Room Opening Architecture。**
全仓生产代码中 **只有 1 个 `RoomPage` 构造点**、**只有 1 个 `MatrixRoomLease` 获取点 / revoke 绑定点 / cancel 点**，全部 5 条"打开房间"代码路径 100% 收敛到 `RoomNavigationCoordinator`（**绕过数 = 0**），并且有 2 个源码级守卫测试在 CI 中持续锁定该事实（本次实测 `16 passed`）。

**端到端层面：还差"最后一段"。**
"统一"目前只覆盖了**页面打开**这一件事；在**离线契约**与**入口能力一致性**上仍有 3 个未收敛点：

| 缺口 | 性质 | 级别 |
| --- | --- | --- |
| 通知 / 推送 / 搜索入口打开既有会话前**先等 Matrix 同步**（最长 10–12 s），失败后**静默无提示** | 违反"已有聊天必须能离线打开" | **P1** |
| 通讯录 / 发现两个 Tab 的搜索页**未注入 `onOpenRoom`**，群聊与聊天记录分组整体不可用（消息 Tab 的同一搜索页可用） | 同一功能在不同入口能力分叉 | **P1/P2** |
| 全局搜索的"群聊"结果**未过滤控制房间**（`畅聊表情仓库` / `畅聊提醒同步`），可被搜到并打开 | 入口作用域不一致（消息列表有过滤） | **P2** |

另有 1 个**外部阻塞项**：工作树当前**无法编译**（3 个 error，位于 `features/search/global_search_page.dart` 与 `features/ledger/ledger_pages.dart`），使"整仓可构建 / 可回归"暂时不成立（与房间打开架构设计无关，但影响验收）。

### 1.2 六项验收问题速答

| # | 问题 | 答案 |
| --- | --- | --- |
| 1 | ChatFlow 有多少进入会话入口？ | 用户可见触发点 **约 20 个**；真正"打开" `RoomPage` 的生产代码路径 **5 条** |
| 2 | 哪些已经统一？ | 全部 5 条路径（含消息列表、好友资料、朋友圈、群成员、搜索、通知/推送/横幅、扫码、好友通过、建群、群聊通讯录）在**页面打开**上 100% 统一 |
| 3 | 哪些绕过？ | 页面打开层面 **0 个绕过**；**能力层面**有 2 处不一致（通讯录/发现搜索无 `onOpenRoom`；搜索未过滤控制房间） |
| 4 | 是否存在多个 RoomPage 创建中心？ | **不存在**。生产代码唯一创建点 `apps/mobile_flutter/lib/app_home.dart:1645` |
| 5 | 是否支持 Offline First？ | **部分支持**：消息列表 / 折叠群聊 / 群聊通讯录 = 离线可开（✅）；通知、推送、搜索入口 = 先等同步（⚠️）；好友"发消息"有本地快路径但慢路径含 15 s 级网络等待（⚠️）；扫码入群 / 建群 / 加好友业务本身需要网络 |
| 6 | 是否达到 Single Room Opening Architecture？ | **页面打开：达成**。**统一会话打开平台：基本达成**，但离线契约与入口能力一致性尚未闭环 |

### 1.3 架构判定

> 本次审计**没有发现**任何"第二个 `RoomPage` 创建中心"、"第二个租约管理中心"、"绕过 canonical room 的私聊创建"或"绕过 E2EE 校验的打开路径"。
> ChatFlow 已经从"多个页面各自打开聊天"进化为"**单一房间打开程序 + 单房间单实例去重**"。
> 但 `RoomNavigationCoordinator` 目前只被当作**导航去重器**使用，尚未成为**打开前的策略闸门**（离线优先、作用域过滤、失败提示都落在各调用方）。

---

## 2. RoomPage Creation Points

### 2.1 全仓 `RoomPage(` 搜索（含测试）

搜索模式：`RoomPage(`、`Navigator.push`、`CupertinoPageRoute`、`MaterialPageRoute`、`openRoomLease`。

| 文件 | 函数 / 位置 | 创建 RoomPage? | 是否生产代码 | 是否统一入口 |
| --- | --- | --- | --- | --- |
| `apps/mobile_flutter/lib/app_home.dart:1645` | `_AppHomeState._openManagedRoomRoute` | ✅ **唯一** | ✅ | ✅ 由 `RoomNavigationCoordinator` 持有的 `openRoom` 程序调用 |
| `apps/mobile_flutter/lib/features/matrix/room_page.dart:152-191` | `class RoomPage` 声明 / 构造函数 | ❌（声明，非创建） | ✅ | n/a |
| `apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart:33` | `export 'room_page.dart' show RoomPage;` | ❌（re-export，无构造） | ✅ | n/a |
| `test/features/matrix/matrix_room_media_ui_test.dart:264,302,356,450` | widget 测试直接 `home: RoomPage(...)` | ✅（测试内） | ❌ | n/a（测试夹具） |
| `test/features/matrix/room_page_nudge_integration_test.dart:147` | 同上 | ✅（测试内） | ❌ | n/a |
| `test/features/matrix/room_page_flash_integration_test.dart:165` | 同上 | ✅（测试内） | ❌ | n/a |
| `test/features/matrix/room_page_anchor_navigation_test.dart:130` | 同上 | ✅（测试内） | ❌ | n/a |
| `test/features/matrix/room_offline_loading_test.dart:130,689,729` | 同上 | ✅（测试内） | ❌ | n/a |
| `test/features/matrix/room_contact_deletion_state_test.dart:69,84,99,126,147` | 同上 | ✅（测试内） | ❌ | n/a |
| `test/features/matrix/profile_message_route_wiring_test.dart:11,26,85` | **源码守卫测试**：断言 `app_home.dart` 中 `builder: (_) => RoomPage(` 恰好出现 1 次，且 `matrix_home_page.dart` / `ContactsTabPage` 中为 0 | ❌（守卫） | ❌ | n/a |

### 2.2 关键判断：是否存在**不经 `RoomNavigationCoordinator`** 的 `RoomPage(...)`

**否。**
- 生产代码 `RoomPage(` 出现次数：**1**（`app_home.dart:1645`）。
- 该 `RoomPage` 由 `_openManagedRoomRoute` 构造，而 `_openManagedRoomRoute` 是通过构造函数 `RoomNavigationCoordinator(openRoom: _openManagedRoomRoute, ...)`（`app_home.dart:205-209`）**只注入给协调器**。任何其它代码路径都没有对 `_openManagedRoomRoute` 的直接引用（唯一调用方是协调器内部的 `_run`）。
- `Navigator.push` 到该 route 的语句同样在 `_openManagedRoomRoute` 内，且必须先 `handle.register(route)`（`app_home.dart:1658`）才能 push。
- **`MaterialPageRoute` 在 `lib/` 全仓 0 处使用**；房间打开使用 `CupertinoPageRoute<void>`。

→ **未发现 Critical Architecture Risk（多创建中心 / 绕过统一导航）。**

### 2.3 其它"看起来像第二条打开路径"的排查（全部排除）

| 候选 | 位置 | 排查结论 |
| --- | --- | --- |
| 消息列表自建租约/页面 | `matrix_home_page.dart` | 已移除。现在只产出 `RoomOpenRequest` 并交给 `widget.onOpenRoom`；守卫测试断言其中不含 `builder: (_) => RoomPage(`、`openRoomLease(`、`setOnRevoked(` |
| `previewOnly` 骨架页 | `main.dart:118-125`（`cachedMessagesBuilder`） | **不是入口**：`_openRoom` / `_openRoomById` 在 `previewOnly` 时直接 return（`matrix_home_page.dart:780,816`），守卫测试覆盖 |
| 通话页 | `app_home.dart:1457-1533` `_openCall` | 共用 `DirectChatController` 解析 roomId，但 push 的是 `CallPage`，**不 push `RoomPage`** |
| `StatisticsRoomScope` | `room_page.dart:607,4300` + `features/statistics/statistics_room_scope.dart` | 只是 RoomPage 内部维护的"当前可见会话"静态栈（供统计工具读），**不创建页面、不取租约** |
| `media_cache.dart:1326` / `media_load_scheduler.dart:74` 的 `lease.cancel` | — | 是 `MediaLoadLease`（媒体下载并发租约），与 `MatrixRoomLease` **无关** |
| `MatrixSdkE2eeClient._managedResources` 中的 lease revoke | `matrix_e2ee_client.dart:5873-5881` | 是 SDK 侧"撤销/换号时统一 revoke"的**下层一致性机制**，不是第二个导航租约管理中心（详见 §7） |

---

## 3. All Entry Points

> 说明：`「统一入口」= 最终由 `RoomNavigationCoordinator.open()` 打开 `RoomPage`。
> 「RoomPage?」= 该入口是否真的会打开会话页。

### 入口 1：消息列表

| 项 | 内容 |
| --- | --- |
| 触发点 | `ConversationListTile.onTap`（`matrix_home_page.dart:929`） |
| 流程 | 消息列表 → 点击会话 → `_openRoom(_RoomSnapshot)`（`:813`）→ `Overlay` 转圈 + 预热身份 → `openRoom(RoomOpenRequest(...))`（`:843`）→ `AppHome._openManagedRoomRequest`（`app_home.dart:1615`）→ `RoomNavigationCoordinator.open` → `_openManagedRoomRoute` → `RoomPage` |
| roomId → 协调器？ | ✅ 是。`RoomOpenRequest.roomId` 为唯一键，**绝不用名称/用户 ID**（`room_navigation_coordinator.dart:22-23`） |
| 已读/未读收尾 | `onRoomReady` 收起转圈 + `setRoomOpen(true)` + `markReadOnOpen`；`onRoomClosed` 恢复列表态（`:852-873`） |
| 结论 | ✅ 统一 |

同源入口（同一 `_openRoom` 路径）：**折叠的群聊列表**（`:1137-1152`）、**群聊/私聊行**、**待处理群邀请**（`:1119` → `_acceptGroupInvite`，**只加入不开房**）。

### 入口 2：通讯录好友

| 项 | 内容 |
| --- | --- |
| 触发点 | `FriendActionColumn` "发消息"（`contact_profile_sections.dart:258-280`）→ `widget.onMessage`（`contacts_page.dart:800-802`） |
| 注入源 | `AppHome._openMessage`（`app_home.dart:1546-1565`），通讯录 Tab 在 `:2028` 注入 |
| 流程 | 通讯录 → 好友资料 → 发消息 → `DirectMessageOpenGate.run(key)` → **闸门内**：`_identityCache()` → `resolveFriendContact`（权威身份）→ `directChats.open(matrixUserId)` → `DirectMessageTarget` → **闸门已释放** → `_openManagedRoom(roomId, roomName, initialContact)` → 协调器 → `RoomPage` |
| `DirectMessageOpenGate` → `DirectChatController` → `RoomNavigationCoordinator`？ | ✅ 完全符合。`direct_chat_entry.dart:146-176` + `app_home.dart:1546-1581` |
| 生命周期边界 | ✅ 闸门只覆盖"身份 + canonical roomId"；`_openManagedRoom` 在闸门**之外**（`app_home.dart:1548-1557`，守卫测试断言顺序） |
| 失败提示 | ✅ `showDirectChatFailureDialog(onRetry: ...)`（`:1562-1563`）——**有明确提示**，非无限 loading |
| 结论 | ✅ 统一（架构上最规范的一条路径） |

### 入口 3：朋友圈

| 项 | 内容 |
| --- | --- |
| 触发点 | `openMomentPerson`（`features/moments/moment_person_navigation.dart:9-60`）：作者头像/昵称 → 本地目录命中 → `ContactProfilePage(onMessage: contactActions?.onMessage)`；未命中 → `AddFriendProfilePage` |
| `ContactActions` 来源 | `AppHome` 统一注入（`app_home.dart:2041-2047` 发现 Tab、`:2059-2065` 我 Tab；好友资料页内嵌朋友圈预览见 `contacts_page.dart:817-819`） |
| 好友：统一 `onMessage`？ | ✅ 是。`onMessage` = `AppHome._openMessage`（同一实现） |
| 非好友 | ✅ 走 `AddFriendProfilePage` → "添加到通讯录"（`add_friend_profile_page.dart:107-122`），**无"发消息"按钮** |
| 结论 | ✅ 统一 |

### 入口 4：群聊成员

| 项 | 内容 |
| --- | --- |
| 触发点 | `openGroupMemberProfile`（`room_page.dart:197-250`） |
| 好友 | `friendContact != null` → `onOpenFriendContact` → `_openContact`（`room_page.dart:2435-2450`）→ `ContactProfilePage(onMessage: widget.onMessage)` → `AppHome._openMessage` ✅ |
| 非好友 | `lookupByMatrixId` 反查业务资料 → `AddFriendProfilePage`（`room_page.dart:217-233`）→ 只能"添加到通讯录"，**不能直接创建聊天** ✅ |
| 自己 | 直接 return（`:209`） ✅ |
| 反查失败 | 明确弹窗"无法获取用户资料"（`:234-249`），不静默 |
| 结论 | ✅ 好友/非好友分流正确；两条分支都不会自行建房 |

### 入口 5：搜索

| 子入口 | 位置 | `onOpenRoom` 注入 | 结果 |
| --- | --- | --- | --- |
| **消息 Tab → 搜索**（`messages-search`） | `matrix_home_page.dart:1060-1077` | ✅ 注入 `_openRoomById` | 群聊 / 聊天记录分组**可见**，点击 → `_openRoomById` → `_openRoom` → 协调器 ✅ |
| **通讯录 Tab → 搜索** | `contacts_page.dart:267-282` | ❌ **未注入** | `canOpenRoom=false`（`global_search_page.dart:260`）→ 群聊 / 聊天记录分组**整体不渲染** |
| **发现 Tab → 搜索** | `discovery_page.dart:53-61` | ❌ **未注入** | 同上 |

分类核对：

- **搜索用户**：结果来自本机身份缓存（`global_search_page.dart:150-159`，仅好友）→ `ContactProfilePage(onMessage: contactActions?.onMessage)` ✅ 统一；非好友不能从搜索直接建聊（搜索源不含非好友）。
- **搜索聊天记录**：`event_id` → `GlobalSearchRoomResult` → `_openRoom(room, anchorEventId)` → `onOpenRoom` → `_openRoomById(roomId, anchorEventId)` → `_openRoom` → `RoomOpenRequest.anchorEventId` → 协调器 → `RoomPage(initialAnchorEventId:)`（`app_home.dart:1650`）→ 进入后定位并高亮 ✅ **通过协调器，且 anchor 走正式契约（不用全局变量/SharedPreferences）**。
- ⚠️ **缺口**：`_openRoomById` 在打开前 `await waitForJoinedRoom(roomId)`（`:782`，最长 12 s）→ 离线时静默失败（见 P1-2）。
- ⚠️ **缺口**：`_loadRooms()`（`global_search_page.dart:170-189`）直接枚举 `snapshot.rooms`，**未过滤控制房间**（见 P2-1）。

### 入口 6：通知 / Push

| 子入口 | 位置 | 是否 `Navigator.push(RoomPage)` |
| --- | --- | --- |
| 系统通知点击 | `routeSystemNotificationPayload`（`system_notification_presenter.dart:17-36`）→ `AppHome._handleNotificationTap`（`app_home.dart:1879-1888`）→ `_openConversationFromNotification` | ❌ **没有**。统一走协调器 |
| 推送（个推 / FCM / Sygnal） | `PushTapRouter.handleTap`（`push_tap_router.dart:73-93`）→ 冷启动挂起 `_pendingRoomId` → `markReady()` 后 `_openConversation`（`:112-122`）→ 同一个 `_openConversationFromNotification` | ❌ **没有** |
| 应用内横幅 | `InAppBannerOverlay.onOpenConversation`（`app_home.dart:2079-2081`） | ❌ **没有** |
| 实现 | `_openConversationFromNotification`（`app_home.dart:1895-1907`）：`waitForRoom(roomId).timeout(10s)` → 埋点 → `_openManagedRoom(roomId)` | ✅ 统一入口；⚠️ 先等网络，失败 catch 后**静默**（见 P1-1） |

### 入口 7：扫码

| 触发点 | `onGroupJoined` 接线 | 入群后 |
| --- | --- | --- |
| `AppHome._scanFromTab`（`app_home.dart:1675-1684`）→ 通讯录/发现"更多"菜单 | → `_openConversationFromNotification(roomId)` | ✅ 统一入口 |
| 消息页"更多" → 扫码（`matrix_home_page.dart:769-776`） | → `_openRoomById(roomId)` | ✅ 统一入口（**另一套处理语义**，见 P2-4） |
| 发现页"扫一扫"列表项（`discovery_page.dart:148-158`） | **未接线** | ❌ 有意不自动打开（注释说明"保持发现页轻量"） |
| 扫码加好友（`scan_qr_page.dart:150-193`） | — | ✅ 只进 `RequestFriendPage`，**不建聊** |

### 入口 8：好友申请 / 通过

| 项 | 内容 |
| --- | --- |
| 触发点 | `FriendRequestsPage._onFriendAccepted`（`contacts_page.dart:1750-1766`）→ `FriendAcceptanceCoordinator` |
| 生产接线 | `AppHome._openFriendRequests` 注入 `onEstablishDirectChatWithRequest`（`app_home.dart:986-989`）→ `_establishDirectChatAndGreet`（`:997-1011`） |
| 流程 | 好友通过 → `ensureCurrentFriendIdentity` → `directChats.open(matrixUserId)`（建/取 canonical DM）→ `sendFriendAccepted`（系统招呼）→ `_openConversationFromNotification(roomId)` → 协调器 → `RoomPage` ✅ |
| 非生产回退 | `establishDirectChat` 回退直接 `directChats.open`（`contacts_page.dart:1757-1763`）——**第二套实现**，生产路径不可达（见 P2-2） |
| 结论 | ✅ 统一（经 `DirectChatController`，未绕过） |

### 入口 9：建群成功

| 项 | 内容 |
| --- | --- |
| `AppHome._createGroupChat`（`app_home.dart:1700-1752`） | `GroupChatPage` → 返回 `roomId` → 身份预热（后台）→ **`await _openManagedRoom(roomId)`**（`:1751`） |
| 结论 | ✅ 统一；守卫测试断言 `source contains 'await _openManagedRoom(roomId);'` |
| 群聊通讯录（通讯录 → 群聊 → 列表） | `_openGroupAddressList`（`:1584-1598`）→ `_openRoomFromAddressList`（`:1600-1601`）→ `_openManagedRoom` ✅ |

---

## 4. Entry Call Graph

### 4.1 统一形态（所有入口的收敛形态）

```
[任意入口]
    │
    ├─ (需要 canonical DM 时) DirectMessageOpenGate.run()
    │        └─ resolveFriendContact() → DirectChatController.open()
    │                 └─ CoordinatedDirectChatGateway.openOrCreateDirectChat()
    │                          ├─ findCachedDirectChat()      （本地，零网络）
    │                          ├─ coordinator.canonicalRoomId()（业务 API）
    │                          ├─ coordinator.claim/publish()   （服务端仲裁）
    │                          └─ createDirectChatOnce() / openExisting()
    │
    ▼
RoomOpenRequest(roomId, roomName, initialContact?, anchorEventId?, onRoomReady?, onRoomClosed?)
    │
    ▼
RoomNavigationCoordinator.open()
    ├─ 已打开 && route.isActive → navigator.popUntil(原 RoomPage)   ← 不叠加第二层
    ├─ _opening[roomId] 存在   → 复用同一个 opening future          ← 并发合并
    └─ 其它                    → _run → openRoom(request, handle)
                                     │
                                     ▼
                        AppHome._openManagedRoomRoute          （唯一 RoomPage 创建程序）
                          ├─ _identityCache()                  （本机 SQLite）
                          ├─ roomDisplayName(roomId)           （本机 SDK 库，仅 roomName 为空时）
                          ├─ matrix.openRoomLease(roomId)      （本机 SDK 库 + 本机历史）
                          ├─ handle.register(route)            ← push 之前登记
                          ├─ lease.setOnRevoked(popUntil self)  ← 唯一 revoke 绑定
                          ├─ navigator.push(route)
                          └─ finally: handle.release + onRoomClosed + lease.cancel
                                     │
                                     ▼
                                 RoomPage（唯一实例 / 每 roomId）
```

### 4.2 各入口 → 协调器的等价链（逐条）

| 入口 | 链路 | 统一？ |
| --- | --- | --- |
| 消息列表行 | 列表 → `_openRoom` → `onOpenRoom` → `RoomNavigationCoordinator.open()` → `RoomPage` | ✅ |
| 折叠群聊 | 同上（`_FoldedGroupChatsPage.onOpen`） | ✅ |
| 消息页搜索（群聊/聊天记录） | 搜索页 → `onOpenRoom` → `_openRoomById` → `_openRoom` → 协调器 → `RoomPage` | ✅（多一跳 `waitForJoinedRoom`） |
| 消息页扫码入群 | 扫码页 → `_openRoomById` → `_openRoom` → 协调器 | ✅ |
| 通讯录/发现扫码入群 | 扫码页 → `_openConversationFromNotification` → `_openManagedRoom` | ✅ |
| 好友资料「发消息」 | `_openMessage` → 闸门 → `directChats.open` → `_openManagedRoom` → 协调器 | ✅ |
| 朋友圈/群成员/资料页 发消息 | 同上（同一个 `onMessage`） | ✅ |
| 好友通过 | `_establishDirectChatAndGreet` → `directChats.open` → `_openConversationFromNotification` → 协调器 | ✅ |
| 建群成功 | `_createGroupChat` → `_openManagedRoom` → 协调器 | ✅ |
| 群聊通讯录 | `_openGroupAddressList` → `_openRoomFromAddressList` → `_openManagedRoom` → 协调器 | ✅ |
| 系统通知点击 | `routeSystemNotificationPayload` → `_openConversationFromNotification` → 协调器 | ✅ |
| 推送点击（冷/热启动） | `PushTapRouter` → `_openConversationFromNotification` → 协调器 | ✅ |
| 应用内横幅 | `InAppBannerOverlay` → `_openConversationFromNotification` → 协调器 | ✅ |
| 通讯录搜索 / 发现搜索 | `GlobalSearchPage(onOpenRoom: null)` → 分组不渲染 → **无链路** | ⚠️ 能力缺失 |
| 通话 | `resolveCallTarget` → `directChats.open`（房间仅作通话信令，**不 push RoomPage**） | n/a |

**错误形态（审计中期望寻找但未发现）：**

```
搜索 → Navigator.push → RoomPage          ← 不存在
通知 → Navigator.push → RoomPage          ← 不存在
任何人 → RoomPage(roomLease: 自建租约)     ← 不存在
```

---

## 5. RoomNavigationCoordinator Coverage

### 5.1 统计

| 指标 | 数量 | 证据 |
| --- | --- | --- |
| 生产代码 `RoomPage` 构造点 | **1** | `app_home.dart:1645` |
| 生产代码 `openRoomLease(` 调用点 | **1** | `app_home.dart:1631` |
| 生产代码 `lease.setOnRevoked(` 调用点 | **1** | `app_home.dart:1659` |
| 生产代码 `lease.cancel()` 调用点 | **2**（同一函数：`!mounted` 分支 `:1640`、`finally` `:1671`） | `app_home.dart` |
| 生产代码 `RoomOpenRequest(...)` 构造点 | **2**（`app_home.dart:1607` 组合根；`matrix_home_page.dart:843` 消息列表）——后者**必须**交给 `onOpenRoom`，不自行打开 | 守卫测试断言 |
| 生产代码"打开房间"调用点（call site） | **5**（见 5.2） | — |
| **统一入口数量** | **5 / 5** | — |
| **绕过数量** | **0** | — |
| **接入率** | **100%** | — |
| `MaterialPageRoute` 使用数（lib） | **0** | 全仓 `grep` |
| 守卫测试 | **2 个文件 / 16 条用例，本次实测全绿** | 见 §12.1 |

### 5.2 五条统一调用点

1. `app_home.dart:1607` `_openManagedRoom()` → `_roomNavigation.open(RoomOpenRequest(...))`
   —— 被 `_openMessage`(`:1555`)、`_openRoomFromAddressList`(`:1600`)、`_createGroupChat`(`:1751`)、`_openConversationFromNotification`(`:1903`) 调用。
2. `app_home.dart:1615` `_openManagedRoomRequest(request)` —— 注入给 `MatrixHomePage.onOpenRoom`（`:2013`）。
3. `matrix_home_page.dart:843` `openRoom(RoomOpenRequest(...))` —— 消息列表侧唯一委托点（不含任何页面/租约构造）。
4. `app_home.dart:205-209` 协调器装配（`openRoom: _openManagedRoomRoute`、`navigatorOf: _rootNavigatorOrNull`）。
5. `app_home.dart:1667` `navigator.push(route)` —— push 之前必经 `handle.register(route)`（`:1658`）。

### 5.3 协调器能力核对（`room_navigation_coordinator.dart`）

| 能力 | 实现 | 测试覆盖 |
| --- | --- | --- |
| 正在打开 → 并发合并 | `_opening[roomId]` + `Completer`（`:132-147`） | Test 3 |
| 已打开 → `popUntil` 回原页 | `_active[roomId]` + `active.isActive`（`:124-129`） | Test 2、Test 5 |
| 打开失败不留假 active | `_run` catch 清理（`:154-159`） | Test 7 |
| 页面退出后清理登记 | `RoomRouteHandle.release`（`:66-70`） | Test 6 |
| 换号/退出不泄漏 | `clear()` / `dispose()`（`:162-171`），`AppHome.dispose` 调用（`:1766`） | Test 8 |
| 租约取消不阻塞其它房间 | 取消在打开流程 `finally` 内、按 roomId 粒度 | Test 9、Test 10 |
| 与 `DirectMessageOpenGate` 分工 | peer 级（闸门） vs roomId 级（协调器），互不替代 | `direct_message_open_lifecycle_test.dart`（本次因 P0-1 无法编译，未运行） |

### 5.4 覆盖率的诚实边界

覆盖率的 100% 只对"**页面打开**"成立。以下**不**由协调器负责，因此仍是各调用方的责任，也是本次发现缺口的来源：

| 能力 | 现状归属 | 是否统一 |
| --- | --- | --- |
| 打开前的网络等待策略 | 各调用方（`_openRoomById`、`_openConversationFromNotification`） | ❌ 不统一 |
| 打开失败的用户提示 | 各调用方（`_openMessage` 有弹窗；通知/搜索**静默**） | ❌ 不统一 |
| 房间作用域过滤（控制房间） | 消息列表 `build` 内过滤；搜索未过滤 | ❌ 不统一 |
| 打开后的已读/未读收尾 | `RoomOpenRequest.onRoomReady/onRoomClosed` 由消息列表实现 | ✅ 契约化 |
| 打开后的统计数据栈 | `RoomPage` 内静态栈 | ⚠️ 第二处会话状态真相源（可接受） |

---

## 6. Direct Chat Creation Audit

搜索：`createDirect`、`directChats.open`、`createRoom`、`m.direct`、`startDirectChat`、`createEncryptedDirectRoom`。

### 6.1 生产链路（唯一）

```
DirectMessageOpenGate（peer 级单飞）
  └─ resolveFriendContact()                      权威身份（业务 userId 为主键）
       └─ DirectChatController.open(matrixUserId)   ← 唯一公开私聊入口
            └─ CoordinatedDirectChatGateway.openOrCreateDirectChat()
                 ├─ findCachedDirectChat()          本地零网络快路径（严格校验）
                 ├─ ApiDirectRoomCoordinator        业务 API 仲裁（canonical / claim / publish）
                 ├─ matrix.findExistingDirectChat() 恢复用（不确定 create 结果时只复用）
                 ├─ matrix.createDirectChatOnce()   一次性建房授权 → is_direct + m.direct + 加密双人校验
                 └─ openExisting → AppHome._openCanonicalDirectRoom
                        └─ MatrixDirectChatBackend.openCanonicalRoom()
                             → startDirectChat / createRoom（仅 avoidRoomId 场景）
                             → addToDirectChat（补写 m.direct）
                             → _ensureHealthy（加密 + 双人；失败先修复、不新建）
```

### 6.2 生产可达的 `client.createRoom()` / `startDirectChat()` 调用点

| 位置 | 调用 | 是否私聊 | 是否经 `DirectChatController` + `CoordinatedDirectChatGateway` |
| --- | --- | --- | --- |
| `matrix_direct_chat_adapter.dart:214` | `client.startDirectChat(enableEncryption: true, ...)` | ✅ DM | ✅ 唯一入口是 `createDirectChatOnce`（已注入 `CoordinatedDirectChatGateway.createOnce`，`app_home.dart:194`） |
| `matrix_direct_chat_adapter.dart:223` | `client.createRoom(isDirect: true, ...)` | ✅ DM | ✅ 仅 `avoidRoomId`（旧房间不健康）分支，同样只在 `createEncryptedDirectRoom` 内 |
| `matrix_group_chat_adapter.dart:16` | `client.createRoom(...)` | ❌ 群聊 | n/a（群建不属于私聊禁令范围；建群后打开仍经协调器） |
| `matrix_e2ee_client.dart:3080` | `client.createGroupChat('畅聊表情仓库')` | ❌ 控制房间 | n/a |
| `matrix_message_reminder_backend.dart:50` | `client.createGroupChat('畅聊提醒同步')` | ❌ 控制房间 | n/a |

**「任何地方 `client.createRoom()` 直接创建私聊」的禁令：✅ 未被违反。**
所有 DM 房间创建都封装在 `MatrixDirectChatBackend.createEncryptedDirectRoom`，其唯一生产入口是通过 `CoordinatedDirectChatGateway.createOnce` 注入的 `MatrixSdkE2eeClient.createDirectChatOnce`。

### 6.3 休眠（dormant）面 —— 需要标注，但当前不可达

| 位置 | 内容 | 生产可达性 |
| --- | --- | --- |
| `matrix_e2ee_client.dart:6358-6361` | `MatrixSdkE2eeClient.openOrCreateDirectChat()` → `DirectChatService.openOrCreateDirectChat()` | ❌ 全仓 `lib/` **无调用者**（仅测试） |
| `direct_chat_service.dart:19-56` | `DirectChatService` / `createOrGetDirectChat()`：可**不经** canonical 协调直接 `createEncryptedDirectRoom()` | ❌ 仅被上面的方法引用 |
| `direct_chat_controller.dart:104-150` | `CanonicalDirectChatGateway`（注释标为 "Legacy directory adapter retained for compatibility tests"） | ❌ 仅测试使用（生产用 `CoordinatedDirectChatGateway`） |
| `contacts_page.dart:1757-1763` | `FriendRequestsPage` 的 `establishDirectChat` 回退：直接 `directChats.open()` | ⚠️ 生产路径被 `onEstablishDirectChatWithRequest` 覆盖，回退不可达（见 P2-2） |

→ 这些是"**潜在的第二私聊创建中心**"。它们今天不会被执行，但缺少架构守卫测试来阻止未来复用（见 P2-3）。

### 6.4 `m.direct` 语义核对

- DM 判定不靠成员数：`conversationRoomType`（`conversation_presentation.dart:139-140`）要求 `isDirectChat (m.direct)` **且** 成员恰为 2；"成员==2 但无 `m.direct`" 判为 **GROUP**（避免历史群被误判私聊）。
- 打开 canonical 房间时会补写 `m.direct`（`matrix_direct_chat_adapter.dart:41-51`），保证 DM 语义与 invite 扫描一致。
- 后端受邀未加入时先 `joinRoomById`（`:16-24`）——**需要网络**（离线打开既有 DM 的例外，见 §8）。
- 加密 + 双人校验在 `_safe`（`coordinated_direct_chat.dart:131-140`）与 `_requireSafe`（`direct_chat_controller.dart:83-88`）双层执行；不达标即抛，**绝不降级为明文或多人房间**。

**结论：✅ 私聊创建链统一，未发现绕过 canonical room 的创建路径。**

---

## 7. RoomLease Audit

搜索：`openRoomLease`、`lease.setOnRevoked`、`lease.cancel`、`MatrixRoomLease`。

### 7.1 生命周期所有权

| 阶段 | 所有者 | 位置 |
| --- | --- | --- |
| 取租约 | `AppHome._openManagedRoomRoute`（唯一） | `app_home.dart:1631` |
| `!mounted` 时取消 | 同上 | `:1639-1642` |
| 路由登记（push 前） | `RoomRouteHandle.register` | `:1658` |
| revoke 绑定 | 同上（唯一 `setOnRevoked`） | `:1659-1664` |
| push | 同上 | `:1667` |
| 页面退出后 release + cancel | 同上 `finally` | `:1668-1672` |
| 换号 / 会话撤销时的强制 revoke | `MatrixSdkE2eeClient._revokeManagedResources()`（SDK 层，调 `lease.revokeNow()`） | `matrix_e2ee_client.dart:5873-5881` |
| 页面内业务操作 | `RoomPage` 通过 `widget.roomLease.*` 使用；`bindOwnerDrain(_drainMatrixOperations)`（`room_page.dart:575`） | 只消费，不创建、不 cancel |

### 7.2 是否存在多个"租约管理中心"？

**否（导航层面）。**
- `openRoomLease` 全仓唯一调用点在 `AppHome`；
- `setOnRevoked` 全仓唯一调用点在 `AppHome`；
- `RoomPage` **不**调用 `lease.cancel()`（`room_page.dart` 中只有 `roomLease.canceled` 读取与 `bindOwnerDrain`）；
- `RoomNavigationCoordinator` 不直接持有 lease——它通过 `RoomOpenProcedure` 注入的 `_openManagedRoomRoute` 间接保证"同 roomId 一次租约"（Test 1/Test 3 断言"只取一次租约"）。

**唯一需要说明的"第二个 revoke 权威"**：`MatrixSdkE2eeClient._revokeManagedResources` 会在**账号撤销/换号/本地清空**时对所有受管资源调用 `revokeNow()`。这不是第二个导航租约中心，而是"SDK 侧安全下线"机制：它保证租约在账号边界上一定会被撤销，与 `AppHome` 的"页面级取消"职责互补。**风险可控，但两者命名接近，容易误读为双中心**（建议在文档/注释中显式区分，见 §10）。

### 7.3 真机 BUG 修复的边界核对

`DirectMessageOpenGate` 的生命周期修复已正确落地：

- 闸门只包住 `_resolveDirectMessageTarget`（`app_home.dart:1548-1551`）；
- `_openManagedRoom` 在闸门**外**（`:1555`）；
- 闸门在成功或失败时都会释放（`direct_chat_entry.dart:164-170`）；
- 因此 Room A 打开期间再次点"发消息"可以走到协调器的 `popUntil`，**不再被静默吞掉**。

---

## 8. Offline Strategy Audit

### 8.1 打开既有会话：各入口的实际等待链

| 入口 | 打开前的等待 | 离线可开？ | 失败表现 |
| --- | --- | --- | --- |
| **消息列表行** | `_identityCache()`（本机 SQLite）→ `roomDisplayName`（本机 SDK 库；列表已给 `roomName` 时跳过）→ `openRoomLease`（本机 SDK 库 + 本机历史）→ push | ✅ **可以**（房间已在本地库即可；`room_offline_loading_test.dart` 已证明缓存消息可离线渲染） | 无网络依赖，不失败 |
| **折叠群聊** | 同上 | ✅ | — |
| **群聊通讯录（通讯录 Tab）** | 列表来自本机 `conversations.snapshot()`（`:54-68`）→ `_openManagedRoom(roomId)`：`roomDisplayName` 本机查询 → 租约本机 | ✅ | `roomDisplayName` 在房间不在本机库时抛错（无 UI 提示） |
| **好友资料「发消息」** | `findCachedDirectChat()`（**纯本地**，绝不 join/request/repair）→ 命中即开；未命中才 `canonicalRoomId()`（业务 API）→ 失败回退 `intents` + 本地 Matrix 库 | ⚠️ **基本可以（best-effort）** | 两条回退都失败 → `showDirectChatFailureDialog`（**有提示**） |
| **好友资料「发消息」（本地状态不完整时）** | `MatrixDirectChatBackend.openCanonicalRoom` → `waitForRoom` → `requestParticipants`；SDK 仅在 `participantListComplete` 时免网络（`third_party/matrix/lib/src/room.dart:1591-1594`），否则 `getMembersByRoom` **最长 15 s**；随后 `_ensureHealthy` 还会 `refreshMembers: true`（再 15 s × N）+ `repairDirectRoom` | ⚠️ **条件性** | 最终抛 `StateError` → 弹窗提示（最长可达数十秒等待） |
| **通知 / 推送 / 横幅** | `waitForRoom(roomId)` = `waitForJoinedRoom`：房间已 join 立即可返回；未 join 则 `waitForRoomInSync(join: true)` 最长 12 s，外层再 `.timeout(10s)` | ⚠️ **条件性** | `catch (_) {}` → **完全静默**，用户看到"点了没反应" |
| **消息页搜索（群聊/聊天记录）** | `_openRoomById` → `await waitForJoinedRoom(roomId)`（最长 12 s）→ `_refreshClientSnapshot()` → 命中 `_rooms` 才打开 | ⚠️ **条件性** | `catch (_) {}` → **静默** |
| **扫码入群后打开** | 入群本身需要网络 → 再 `_openConversationFromNotification` | ❌（业务需网络） | 静默 |
| **好友通过后打开** | `sendFriendAccepted` 需要网络 | ❌（业务需网络） | 由好友接受流程负责 |
| **建群成功后打开** | 建群本身需要网络；打开走本机租约 | ✅（在已建群的前提下） | — |

### 8.2 新建聊天（无既有房间）

| 场景 | 离线行为 | 提示 |
| --- | --- | --- |
| 已有好友、无 DM → 首次发消息 | `findCached` miss → `canonicalRoomId()` 失败 → 回退本地 intent / `findExisting`；两者皆无 → **抛原始网络错误** | ✅ `showDirectChatFailureDialog(onRetry:)` |
| 已在服务端 claim 到 `may_create` 但网络中断 | 不重放创建（`createOnce` 只在授权分支调用一次）→ 等待窗口结束抛 `DirectRoomPendingException`（"私聊正在同步，请稍后重试；不会重复创建房间。"） | ✅ 明确文案 |
| 陌生用户发起聊天 | **架构上不允许**：搜索/群成员/朋友圈对非好友只给"添加到通讯录" | n/a |

### 8.3 离线策略结论

- **符合**"已有聊天必须能离线打开"的入口：消息列表、折叠群聊、群聊通讯录（3/9）。
- **条件性**（房间已在本机库 → 可开；否则先等同步）：通知/推送/横幅、搜索、好友资料慢路径（3/9）。
- **业务本身需要网络**：扫码入群、好友通过、建群、首次私聊。
- **违反**"不能无限 loading / 失败必须明确提示"的入口：通知/推送/横幅与消息页搜索 —— 最长 10–12 s 的等待后**静默无任何反馈**（**P1**）。

---

## 9. Architecture Risks

> 本节只记录，**不修复**。格式：问题 / 位置 / 当前行为 / 风险 / 建议方案 / 影响范围。

### P0-1（构建完整性，非本架构设计缺陷）工作树无法编译

- **问题**：审计基线（工作树）存在 3 个编译错误，"整仓可构建、可回归"不成立。
- **位置**：
  - `apps/mobile_flutter/lib/features/search/global_search_page.dart:21-23`（`import '../matrix/chat_search_query_controller.dart'` 后插入了 `import '../../ui/motion/motion_page_route.dart';`，使原 `show ... ;` 悬空）——`expected_token` + `undefined_class 'show'`
  - `apps/mobile_flutter/lib/features/ledger/ledger_pages.dart:379`（`switch (entry)` 非穷尽）——`non_exhaustive_switch_expression`
- **当前行为**：`flutter analyze lib/features/search/global_search_page.dart lib/features/ledger/ledger_pages.dart` → `3 issues found`（exit 1）。任何 `import app_home.dart` 或 `matrix_home_page.dart` 的测试**无法编译**（实测 `direct_message_open_lifecycle_test.dart`、`matrix_home_room_delegation_test.dart` 加载失败）。
- **风险**：无法对"统一房间打开"做端到端回归；搜索入口（本次审计的入口 5）当前不可构建；若被误当成"已通过门禁"会造成假绿。
- **建议方案**：（由负责人决定，本次不修）修正 import 结构、补 `switch` 通配分支；修复后至少运行 `profile_message_route_wiring_test.dart`、`room_navigation_coordinator_test.dart`、`matrix_home_room_delegation_test.dart`、`direct_message_open_lifecycle_test.dart` 与 `flutter analyze`。
- **影响范围**：全局构建 / 测试；入口 5（搜索）；账本页 UI。（与 `RoomNavigationCoordinator` / `RoomLease` / `DirectChatController` 无因果关系。）

### P1-1 通知 / 推送 / 横幅入口先等 Matrix 同步，失败静默无提示

- **问题**：打开"已有会话"前强制等待 `waitForRoom`，离线或冷启动未同步时最长 10 s 后**静默放弃**。
- **位置**：`apps/mobile_flutter/lib/app_home.dart:1895-1907`（`_openConversationFromNotification`）；`matrix_e2ee_client.dart:831-843`（`waitForJoinedRoom`：`waitForRoomInSync` 12 s）。
- **当前行为**：`await waitForRoom(roomId).timeout(10s)` → 成功则 `_openManagedRoom`；任何异常被 `catch (_) {}` 吞掉，不弹窗、不提示、不重试。
- **风险**：离线用户点通知 → 10 秒无反应且无解释（体验等同"点击失效"）；违反本次审计的离线原则与"失败必须明确提示、不能无限 loading"的约束；推送点击是高频路径（个推/Sygnal/冷启动）。
- **建议方案**（记录，不实施）：本地已 join 的房间直接走同步路径（`client.getRoomById` 命中即跳过 `waitForRoomInSync`）；仅在缺失时等待，并在超时后给出明确的"网络不可用，稍后重试"提示（可带重试按钮）；把超时/失败原因写入通知诊断（`NotificationDiagnostics`）。
- **影响范围**：系统通知点击、推送冷/热启动、应用内横幅、扫码入群后打开、好友通过后打开。

### P1-2 搜索入口打开既有会话前先等同步，离线静默失败

- **问题**：搜索命中群聊/聊天记录后，必须先 `waitForJoinedRoom` 并重刷列表快照，离线时静默无反应。
- **位置**：`apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart:779-789`（`_openRoomById`）。
- **当前行为**：`await conversations.waitForJoinedRoom(roomId)`（未 join 时最长 12 s）→ `_refreshClientSnapshot()` → 只有命中 `_rooms` 才 `_openRoom`；异常 `catch (_) {}`。
- **风险**：搜索是为了快速回到一条历史消息，而"本机已有该房间 + 本机已有该事件"恰恰是离线最可用的场景，却被网络门挡住；与入口 1（列表行，零网络依赖）形成**同一会话两种行为**。
- **建议方案**：`client.getRoomById(roomId)?.membership == join` 时直接构造 `RoomOpenRequest`（含 `anchorEventId`）交给协调器；仅在房间缺失时才等待/提示。
- **影响范围**：消息 Tab 搜索（群聊 + 聊天记录，含锚点定位）。

### P1-3 通讯录 / 发现搜索未注入 `onOpenRoom`，同一功能能力分叉

- **问题**：同一个 `GlobalSearchPage` 在消息 Tab 可打开会话，在通讯录/发现 Tab 连"群聊/聊天记录"分组都不渲染。
- **位置**：`apps/mobile_flutter/lib/features/contacts/contacts_page.dart:267-282`、`apps/mobile_flutter/lib/features/discovery/discovery_page.dart:53-61`（均未传 `onOpenRoom`）；判定在 `global_search_page.dart:260`（`canOpenRoom = widget.onOpenRoom != null`）。
- **当前行为**：不展示分组（`canOpenRoom && rooms.isNotEmpty` / `conversations.isNotEmpty`），点击联系人仍可进资料页发消息。
- **风险**：不是"绕过统一入口"（没有第二条打开实现），而是**入口能力不一致**：用户从通讯录搜索历史消息会以为"搜索不到聊天记录"；同一功能的三种行为使后续演进（离线策略、anchor、控制房间过滤）必须逐入口修，容易漏。
- **建议方案**：把 `onOpenRoom` 作为组合根（`AppHome`）统一注入给所有 `GlobalSearchPage`（或把 `GlobalSearchPage` 的房间打开能力收敛为必需参数，缺失即编译期报错）。
- **影响范围**：通讯录 Tab 搜索、发现 Tab 搜索。

### P2-1 全局搜索的群聊结果未过滤控制房间

- **问题**：全局搜索的"群聊"分组未应用 `isMatrixControlRoom`，控制房间可被检索并打开成 `RoomPage`。
- **位置**：`apps/mobile_flutter/lib/features/search/global_search_page.dart:170-189`（`_loadRooms`：直接枚举 `snapshot.rooms`）；对比消息列表 `matrix_home_page.dart:1017-1026`（过滤 `vaultRoomId` / `reminderRoomId` / 名称白名单）。
- **当前行为**：控制房间 `畅聊表情仓库`（`matrix_e2ee_client.dart:3079-3087`）与 `畅聊提醒同步`（`matrix_message_reminder_backend.dart:50-57`）均由 `createGroupChat` 创建（`isDirect == false`），因此会进入搜索的群聊候选；`_openRoomById` 在 `_rooms` 中能命中，最终经协调器打开。
- **风险**：内部 E2EE 控制房间对用户可见/可进入，用户可误发消息、误改设置，破坏"表情仓库/提醒同步"的语义假设；同时说明"入口作用域策略"目前分散在各入口，未被统一。
- **建议方案**：`_loadRooms` 复用 `isMatrixControlRoom(roomId, displayName, vaultRoomId, reminderRoomId)`；更彻底的做法是把"可见/可打开房间集合"作为协调器的前置策略（`RoomOpenRequest` 校验），使所有入口自动继承。
- **影响范围**：消息 Tab 搜索（群聊分组）。

### P2-2 好友接受链路存在第二套"建立私聊"实现（生产不可达）

- **问题**：`FriendRequestsPage` 保留 `establishDirectChat` 回退，直接调用 `DirectChatController.open()`，绕过"建立私聊 + 发送接受招呼 + 打开会话"的编排。
- **位置**：`apps/mobile_flutter/lib/features/contacts/contacts_page.dart:1750-1766`（回退分支 `:1757-1763`）；生产接线见 `app_home.dart:986-989`。
- **当前行为**：`AppHome` 注入了 `onEstablishDirectChatWithRequest`，回退在当前生产组合下**不可达**；但代码仍在，且缺少断言阻止它被再次使用。
- **风险**：重复实现漂移（例如未来回退被复用后，"接受好友却不发招呼/不打开会话"会静默发生）；破坏"私聊建立只有一条编排"的可读性。
- **建议方案**：删除该回退，或标注 `@visibleForTesting` 并加架构守卫测试断言生产组合必传 `onEstablishDirectChatWithRequest`。
- **影响范围**：好友接受/新的朋友流程。

### P2-3 休眠的 legacy 私聊创建面（潜在第二创建中心）

- **问题**：存在一条**不经** `CoordinatedDirectChatGateway` 的私聊创建路径，当前无生产调用者。
- **位置**：`apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart:6358-6361`（`openOrCreateDirectChat`）→ `direct_chat_service.dart:19-56`（`DirectChatService.openOrCreateDirectChat` → `createEncryptedDirectRoom`）；`direct_chat_controller.dart:104-150`（`CanonicalDirectChatGateway`，注释已标"compatibility tests"）。
- **当前行为**：全仓 `lib/` 无调用者（仅测试引用）。
- **风险**：只要被复用一次，就会退化为"两个私聊创建中心"——绕过 canonical 仲裁与服务端 claim/publish，可能产生重复 DM（这正是 `CoordinatedDirectChatGateway` 要解决的跨设备竞态）。
- **建议方案**：删除或 `@Deprecated` + 架构守卫测试（例如断言 `lib/` 中除 `app_home.dart` 外无 `openOrCreateDirectChat(` / `createEncryptedDirectRoom(` 调用）。
- **影响范围**：私聊创建链的长期一致性。

### P2-4 同一"扫码入群后打开群"存在两套处理语义

- **问题**：两处 `ScanQrPage` 的 `onGroupJoined` 接线到不同实现。
- **位置**：`app_home.dart:1675-1684`（`_scanFromTab` → `_openConversationFromNotification`）vs `matrix_home_page.dart:769-776`（→ `_openRoomById`）；`discovery_page.dart:148-158`（**不接线**）。
- **当前行为**：三者分别表现为"等待房间就绪后打开" / "等待 join 且必须在列表快照中命中" / "只入群不打开"。
- **风险**：终态都是协调器，无绕过；但行为不一致导致同一操作在不同 Tab 有不同成功率（尤其"必须在 `_rooms` 中命中"这一条件），且离线策略（P1-1/P1-2）需要重复修复。
- **建议方案**：统一为组合根注入的单一回调（例如 `AppHome._openConversationFromNotification`），并明确"入群后是否自动打开"的产品决策。
- **影响范围**：消息页扫码、通讯录/发现"更多"扫码、发现页"扫一扫"。

### P2-5 会话状态存在第二处真相源（`StatisticsRoomScope`）

- **问题**：除协调器的 `_active` 登记外，`RoomPage` 还维护一个全局静态"当前会话栈"。
- **位置**：`room_page.dart:607`（`enter`）、`:4300`（`leave`）、`features/statistics/statistics_room_scope.dart`。
- **当前行为**：`RoomPage` 进入/离开时压栈/出栈；统计工具读取栈顶。
- **风险**：低（协调器保证同 roomId 单实例，多房间叠放时栈语义正确）。但在页面生命周期异常（如 route 被外部 pop）时可能出现与 `_active` 不一致的短暂窗口。
- **建议方案**：若后续需要严格一致，可由协调器在 register/release 时统一通知该作用域，而不是由页面自行维护。
- **影响范围**：统计工具上下文；架构可读性。

### 未列为风险但需记录的观察

| 观察 | 说明 |
| --- | --- |
| `MatrixRoomLease` 的"页面级取消"（AppHome）与"账号级 revoke"（SDK）并存 | 职责互补、命名接近；建议注释显式区分，避免被误读为双租约中心 |
| `_establishDirectChatAndGreet` 中 `directChats.open` 成功但 `sendFriendAccepted` 失败 | 房间已建立、招呼未发；`open` 幂等、招呼用固定 txid（`friendAcceptedTransactionId`），重试安全，风险可接受 |
| `RoomNavigationCoordinator` 允许 A 之上叠 B（Test 4） | 这是**有意语义**："每 roomId 单实例"而非"同时只有一个会话页"；`popUntil` 只作用于同 roomId |
| `Media Engine Phase 4`（服务端） | **未引入任何新的会话打开入口**：新增的是 `/media/platform/**` HTTP 面与平台对象/引用/授权，Flutter 侧未接入（报告 §1.2 "Flutter 客户端改造 … 属下一阶段"）。`RoomPage` 相关代码本次未改动 |
| `MatrixControlRoom` 名称白名单是字面量 | `'畅聊表情仓库' / '畅聊提醒同步'` 为硬编码中文名；改名即失效（P2-1 的加固方案应同时依赖 accountData 的 room_id） |

---

## 10. Recommended Improvements

> 仅为建议，**本次未实施**。按投入/收益排序。

| # | 建议 | 对应风险 | 收益 |
| --- | --- | --- | --- |
| R1 | **修复工作树编译错误**并恢复门禁（`flutter analyze` + 房间打开相关测试） | P0-1 | 让"统一打开"重新可验证；消除假绿 |
| R2 | 把**离线优先策略上移**到 `RoomNavigationCoordinator`：本地已 join 的房间直接打开，网络等待只发生在"房间不在本机库"时；打开前策略（作用域校验、可见性）作为协调器的一部分 | P1-1、P1-2、P2-1 | 一处修复覆盖所有入口；真正实现"统一会话打开平台"而非"统一导航" |
| R3 | 为**打开失败**建立统一反馈契约：`RoomOpenRequest` 增加 `onOpenFailed(error)` 或让 `open()` 的错误由组合根统一弹窗；禁止调用方 `catch (_) {}` 吞掉打开失败 | P1-1、P1-2 | 消除"点了没反应"；满足"失败必须明确提示" |
| R4 | **统一搜索页的房间打开能力**：`onOpenRoom` 由组合根对三处 `GlobalSearchPage` 统一注入（或改为必需参数） | P1-3 | 入口能力一致；后续策略只改一处 |
| R5 | 在搜索的房间候选上应用 `isMatrixControlRoom`（以 accountData room_id 为准，名称白名单仅作兜底） | P2-1 | 控制房间不再暴露 |
| R6 | 增加**架构守卫测试**：断言 `lib/` 中 `RoomPage(` / `openRoomLease(` / `setOnRevoked(` / `openOrCreateDirectChat(` / `createEncryptedDirectRoom(` 的调用点集合恒等于白名单 | P2-2、P2-3 | 结构不变量由 CI 强制，防止回退 |
| R7 | 删除/标注 legacy 私聊面（`DirectChatService`、`CanonicalDirectChatGateway`、客户端 `openOrCreateDirectChat`） | P2-3 | 消除潜在第二创建中心 |
| R8 | 统一扫码入群的回调语义（单一 `onGroupJoined` 实现 + 明确是否自动打开） | P2-4 | 行为一致、离线策略一次生效 |
| R9 | 把 `StatisticsRoomScope` 的进入/离开改为由协调器 register/release 驱动 | P2-5 | 单一会话状态真相源 |
| R10 | 在 `RoomNavigationCoordinator` / `MatrixRoomLease` 的文档中显式区分"页面级 cancel（AppHome）"与"账号级 revoke（SDK）" | 观察项 | 降低误读为双中心的风险 |

---

## 11. Final Assessment

### 11.1 六项验收问题（正式回答）

**1. ChatFlow 当前有多少入口可以进入会话房间？**
- 用户可见触发点 **约 20 个**（消息列表行、折叠群聊、消息页搜索×3、消息页扫码、通讯录群聊、通讯录搜索、通讯录扫码、好友资料发消息、朋友圈作者、朋友圈预览、群成员×2、好友通过、建群成功、系统通知、推送、应用内横幅、发现搜索、发现扫码；另通话入口共用私聊解析但不打开房间）。
- 真正会"打开 `RoomPage`"的**生产代码路径 5 条**（§5.2）。

**2. 哪些已经统一？**
- **全部 5 条路径 / 20 个触发点，在"页面打开"上已统一**：唯一 `RoomPage` 构造点、唯一 `openRoomLease`、唯一 `setOnRevoked`、唯一 `navigator.push`，全部经 `RoomNavigationCoordinator`（roomId 级去重 + `popUntil` 复用 + 打开中合并）。
- 私聊创建链同样统一：`DirectMessageOpenGate` → `DirectChatController` → `CoordinatedDirectChatGateway`，未发现绕过 canonical 仲裁的创建。

**3. 哪些绕过？**
- **页面打开层面：0 个绕过。**
- **能力/策略层面 2 处不一致**（非绕过，但属于"入口未完全统一"）：通讯录/发现搜索未注入 `onOpenRoom`（群聊/聊天记录不可用）；搜索的群聊候选未过滤控制房间。

**4. 是否存在多个 RoomPage 创建中心？**
- **不存在。** 生产代码 1 个（`app_home.dart:1645`），且有源码级守卫测试（`profile_message_route_wiring_test.dart`）在 CI 中锁定；测试夹具中的多处构造不构成生产中心。

**5. 是否支持 Offline First？**
- **部分支持。**
  - ✅ 已实现：消息列表、折叠群聊、群聊通讯录（房间在本机库即可离线打开；本机缓存消息可离线渲染）。
  - ⚠️ 未实现：通知/推送/横幅、搜索入口（先等 10–12 s 同步，失败**静默**）；好友"发消息"慢路径含 15 s 级网络等待。
  - ➖ 业务本身需网络：扫码入群、好友通过、建群、首次私聊（这部分失败并有明确提示，符合要求）。

**6. 是否达到 Single Room Opening Architecture？**
- **页面打开架构：达到（Achieved）**——单一创建点、单一租约所有者、单一去重键、单一私聊创建链，绕过数为 0。
- **"统一会话打开平台"：基本达到（Mostly achieved）**，尚缺三件事才算完整：
  1. 打开前的**离线优先策略**必须上移到协调器（而不是散落在调用方）；
  2. 打开失败的**统一反馈契约**（禁止静默吞错）；
  3. **入口作用域/能力一致性**（搜索三处同能力、控制房间统一过滤）。
- **验收结论**：ChatFlow 已经完成从"多个页面打开聊天"到"**单一房间打开程序**"的进化；下一步不是再加协调器，而是让协调器从"导航去重器"升级为"**打开策略闸门**"。

### 11.2 审计证据与复现（本次实测）

| 检查 | 命令 / 方法 | 结果 |
| --- | --- | --- |
| `RoomPage` 构造点穷举 | `grep -r "RoomPage(" apps/mobile_flutter` | 生产 1 处（`app_home.dart:1645`）；其余为声明/re-export/测试 |
| 租约与 revoke 穷举 | `grep -r "openRoomLease\|setOnRevoked\|lease\.cancel"` | `openRoomLease` 1 处、`setOnRevoked` 1 处（均在 `_openManagedRoomRoute`） |
| `MaterialPageRoute` | `grep -r MaterialPageRoute apps/mobile_flutter/lib` | 0 处 |
| 私聊创建穷举 | `grep -r "createRoom\|startDirectChat\|createEncryptedDirectRoom\|openOrCreateDirectChat"` | 生产可达 DM 创建只在 `MatrixDirectChatBackend`，唯一入口 `createDirectChatOnce` |
| 结构守卫测试 | `flutter test test/features/matrix/profile_message_route_wiring_test.dart test/features/matrix/room_navigation_coordinator_test.dart` | **`All tests passed!`（16 passed，exit 0）**：5 条源码守卫 + 11 条协调器行为（含"只取一次租约"、"同房间 popUntil 不叠层"、"A→B 正常"、"异常清理"、"换号不泄漏"、"租约取消不阻塞其它房间"） |
| 端到端打开链测试 | `flutter test .../matrix_home_room_delegation_test.dart .../direct_message_open_lifecycle_test.dart` | **加载失败**：因 P0-1 的 `global_search_page.dart` 编译错误（`Compilation failed`）——**本次无法验证**，已在 P0-1 记录 |
| 静态分析 | `flutter analyze lib/features/search/global_search_page.dart lib/features/ledger/ledger_pages.dart` | `3 issues found`（exit 1）：`expected_token`、`undefined_class 'show'`、`non_exhaustive_switch_expression` |

**未执行项（诚实记录）**：真机验证、APK/IPA 构建、全量 `flutter test`、`scripts/verify.ps1`。原因：本次为只读架构审计；且工作树存在 P0-1 编译错误，全量门禁在当前基线下无意义。所有结论均来自**工作树源码 + 可运行的结构/行为守卫测试 + 静态分析**；未对任何文件做修改。

---

*报告结束。本次审计未修改任何 Dart / Flutter / Matrix / RoomPage / RoomLease / Navigator / DirectChatController / Media Engine 代码。*
