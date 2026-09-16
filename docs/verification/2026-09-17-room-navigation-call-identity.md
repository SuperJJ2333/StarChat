# 2026-09-17 第二阶段：房间导航统一（RoomNavigationCoordinator）+ 通话身份修复

承接[第一阶段「好友资料 → 私聊入口统一」](2026-09-17-unified-direct-message-entry.md)。
本阶段只处理两个遗留问题：① 消息列表直接打开 RoomPage 仍是第二套路由生命周期；
② `_openCall` 仍使用入口快照里可能过期的 `contact.matrixUserId`。
未改 Matrix 房间创建协议、`CoordinatedDirectChatGateway`、`DirectChatController` 的 canonical
逻辑、E2EE/Olm/Megolm、登录/L04/L07、个推/FCM/APNs、通话媒体/WebRTC/TURN/ICE、群聊业务规则、
朋友圈逻辑、好友 schema、Matrix SDK adapter 结构与 UI 样式。
**未构建 APK/IPA、未安装真机、未部署**（用户要求本次不做）。

## 1. Root Cause

| 问题 | 根因 |
| --- | --- |
| A：消息列表 RoomPage 第二套路由 | `MatrixHomePage._openRoom` 自己 `openRoomLease` + 建 `RoomPage` + `setOnRevoked` + `Navigator.push` + 取消租约，并用**全局 `bool _openingRoom`** 做守卫。因此「Room A → 好友资料 → 发消息（canonical 仍是 Room A）」会在 Room A 之上再 push 一个 Room A（两个 RoomPage、两份 RoomLease），而全局守卫只是「有任意房间在打开时禁止打开其它房间」，既不解决 roomId 级唯一性，又会在某些时序下吞掉其它会话的点击。 |
| B：`_openCall` 用 stale matrixUserId | 通话入口用 `ensureCurrentFriendIdentity(cache, contact.matrixUserId)` 校验、用 `directChats.open(contact.matrixUserId)` 开房、用 `calls.start(matrixUserId: contact.matrixUserId)` 发起呼叫，并把 `contact.displayName/username/avatarUrl` 交给 `CallPage`。入口快照可能来自旧缓存/群成员快照/朋友圈作者/改绑前的数据，于是**房间用新身份、通话拨给旧 Matrix 用户、页面显示旧资料**。与第一阶段已经建立的「业务 userId 为主键」规则不一致。 |

## 2. RoomPage 入口审计（修改后，全生产代码）

| # | 入口 | 调用链 | 分类 |
| --- | --- | --- | --- |
| 1 | 好友资料「发消息」（通讯录 / 朋友圈 / 群聊 / 会话资料 / 搜索） | `ContactProfilePage.onMessage` → `AppHome._openMessage` → `resolveFriendContact` → `directChats.open` → `_openManagedRoom` | A 已统一（阶段一）+ 本阶段纳入协调器 |
| 2 | 消息列表会话行、折叠群聊、`_openRoomById` | `MatrixHomePage._openRoom` → `onOpenRoom(RoomOpenRequest)` → `AppHome._openManagedRoomRequest` → 协调器 | **B 本阶段修改** |
| 3 | 通知/推送点击打开会话 | `AppHome._openConversationFromNotification` → `_openManagedRoom` | B（逻辑不变，自动纳入 roomId 去重） |
| 4 | 通讯录 → 群聊通讯录列表 | `AppHome._openRoomFromAddressList` → `_openManagedRoom` | B（自动纳入） |
| 5 | 接受好友后建会话并打开 | `_establishDirectChatAndGreet` → `directChats.open` → `_openConversationFromNotification` | B（自动纳入） |
| 6 | 建群成功后打开新群 | `_createGroupChat` 尾部 → `_openManagedRoom(roomId)` | **B 本阶段改为复用**（极小改动：删掉自建租约/路由/revoke） |
| 7 | 扫一扫进群后打开 | `_scanFromTab` → `onGroupJoined` → `_openConversationFromNotification` | B（自动纳入） |
| 8 | 通话页 / 来电页 | `CallPage`（不是 RoomPage） | C 保留（不在本阶段范围） |
| 9 | 测试代码中的 RoomPage/租约假实现 | `test/**` | D |

**结论：生产代码里 `builder: (_) => RoomPage(` 只剩 1 处**（`app_home.dart` 的协调器打开流程
`_openManagedRoomRoute`）；`openRoomLease(` 在生产代码里只剩该流程内的 1 处（另一处是
`matrix_e2ee_client.dart` 的实现定义）。`matrix_home_page.dart` 不再包含
`RoomPage(` / `openRoomLease(` / `setOnRevoked(`。

## 3. 修改前导航结构

```
消息列表行 ──► MatrixHomePage._openRoom（自建）
                │ overlay + 预热 + readState
                ├─ await openRoomLease(roomId)        ← 第二套租约生命周期
                ├─ CupertinoPageRoute(RoomPage)       ← 第二套路由
                ├─ lease.setOnRevoked(popUntil+removeRoute+await popped)
                └─ await Navigator.push(route) … finally unawaited(lease.cancel())
                （守卫：全局 bool _openingRoom）

好友资料 ──► AppHome._openMessage ──► directChats.open ──► _openManagedRoom（各入口共用）
                                                          ├─ openRoomLease
                                                          ├─ CupertinoPageRoute(RoomPage)
                                                          ├─ lease.setOnRevoked(popUntil+pop)
                                                          └─ await push … finally await cancel
通知/地址簿/建群 ──►各自调用 _openManagedRoom，或（建群）自建第三份路由
```

## 4. 修改后导航结构

```
消息列表行 ──► MatrixHomePage._openRoom（只做列表侧职责）
                │ overlay + _warmChatIdentity + 展示数据(roomId/roomName)
                │ Set<String> _openingRooms  ← 同房间重复点击去重（不再用全局 bool）
                └─ await onOpenRoom(RoomOpenRequest{onRoomReady,onRoomClosed})
                        │
好友资料 ──► AppHome._openMessage ──► resolveFriendContact ──► directChats.open
                        │
通知/地址簿/建群 ────────┘
                        ▼
        RoomNavigationCoordinator.open(RoomOpenRequest)   ← roomId 唯一键
                        ├─ 已在打开中 → 复用同一个 opening future（不重复取租约/push）
                        ├─ 已打开     → Navigator.popUntil(既有 route)（不 push 第二层）
                        └─ 未打开     → _openManagedRoomRoute（唯一 RoomPage 构建点）
                                          ├─ openRoomLease(roomId)
                                          ├─ RoomPage + handle.register(route)
                                          ├─ lease.setOnRevoked(popUntil 自身 + 当前则 pop)
                                          ├─ request.onRoomReady?.call()      → 列表侧已读收尾/收 overlay
                                          ├─ await Navigator.push(route)
                                          └─ finally: handle.release(route) + onRoomClosed + await lease.cancel()
```

## 5. RoomNavigationCoordinator 设计

文件：`lib/features/matrix/room_navigation_coordinator.dart`（约 160 行，含文档）。

- `RoomOpenRequest`：`roomId` + `roomName` + `initialContact` + 两个生命周期回调
  （`onRoomReady` 租约就绪、push 前；`onRoomClosed` 页面退出/失败后一次）。**不含**
  Matrix SDK 对象、RoomLease、BuildContext。
- `RoomRouteHandle`：打开流程与协调器之间的登记句柄（`register` / `release` / `route`）。
- `RoomNavigationCoordinator`：
  - `Map<String, Future<void>> _opening`（roomId → 在打开的 future）
  - `Map<String, Route<void>> _active`（roomId → 活动路由）
  - `open(request)` / `clear()` / `dispose()`，以及 `@visibleForTesting` 的
    `isOpening`/`activeRoute`/`openingCount`/`activeRoomIds`。
- 打开流程 `openRoom: _openManagedRoomRoute` 与根 Navigator 解析 `navigatorOf` 由 AppHome 注入
  （`_rootNavigatorOrNull`，未 mounted 时返回 null，不抛异常）。
- **关键实现细节（由测试暴露后修正）**：
  1. `_active` 必须**先于** `_opening` 判断——打开流程会一直持有到页面关闭，若先判 `_opening`
     会把「房间已打开」误判为「正在打开」，从而并进旧 future 而不是回到原页面。
  2. `register(route)` 同时清掉 `_opening[roomId]`：路由一旦建立，打开阶段即结束；
     这样页面退出后租约还在取消（真机可达 6 秒）时再次打开同一房间会**新开页面**，而不是静默无操作。
  3. `_opening` 必须**先占位再启动流程**：打开流程在第一个 `await` 之前是同步执行的
     （会直接 `register` 路由），若先启动流程再写 map，登记会被随后的赋值覆盖，opening 永远不清理。

## 6. active room 去重规则

- 键为 **Matrix roomId**（群聊与私聊一致）；不使用 roomName/displayName/userId/matrixUserId。
- `_active[roomId]?.isActive == true` → `Navigator.popUntil(identical(route))`，返回**已完成的**
  future（调用方无需等待页面关闭）；不 push 新页面。
- 登记失效（route 非 active）时兜底移除后按「未打开」处理。
- 页面退出/打开失败：`handle.release(route)` 只释放自己登记的那条 route；协调器在异常路径
  也会清理（`_run` catch，防止流程忘记释放时留下假 active）。

## 7. opening room 并发规则

- `_opening[roomId]` 存在 → 直接返回该 future（第二次请求不取租约、不 push）。
- 页面退出后租约取消期间，`_opening` 已被 `register` 清空 → 新请求会正常新开页面；
  其它 roomId 的请求从不受影响（**没有全局 bool**）。
- 完成/失败后 `_opening[roomId]` 一定被移除（`then/onError` 中按 future 身份比对，避免误删后来者）。

## 8. RoomLease 生命周期

保留原有全部语义，并按 roomId 串行：

```
open → 登记 opening → openRoomLease → mounted 检查（未 mounted ⇒ cancel 并返回）
     → 构建 RoomPage → register(route) → setOnRevoked 绑定 → onRoomReady
     → push → finally { release(route); onRoomClosed; await lease.cancel() }
     → _opening 移除
```

- push 抛异常 ⇒ `finally` 释放登记与租约，协调器再兜底清理活跃登记。
- 未 mounted ⇒ 取消租约、不 push、不触发 onRoomReady/onRoomClosed（列表侧自己收 overlay）。
- 租约取消**只影响同一 roomId**：`Test 9` 断言 A 的取消被挂住时 B 仍可立即打开；
  `Test 10` 断言期间重开 A 会新开页面。

## 9. revoke 行为

由打开流程绑定，与改造前 `_openManagedRoom` 完全一致：`route.isActive` 时
`popUntil(identical(route))`，若 `route.isCurrent` 再 `pop()`——只关闭这一层房间页，
不误 pop 多层、不 remove 错 route（不再有第三种 `removeRoute + await route.popped` 写法）。
`Test 6` 覆盖「退出 → registry 清理 → 可重开」，`onRoomReady/onRoomClosed` 顺序另有专测。

## 10. `_openCall` 身份修复

```dart
final cache = await _identityCache();
final target = await resolveCallTarget(
    cache: cache, directChats: directChats, entry: contact); // 与「发消息」同一解析
final authoritative = target.contact;
...
CallPage(displayName: authoritative.displayName,
         fallbackSeed: authoritative.username,
         avatarUrl: authoritative.avatarUrl, ...)
await calls.start(roomId: target.roomId,
                  matrixUserId: authoritative.matrixUserId.trim(),
                  type: type);
```

- `resolveCallTarget`（`direct_chat_entry.dart`）复用 `resolveFriendContact`：
  业务 userId 为主键取权威联系人 → 用**权威 matrixUserId** 走 `DirectChatController`
  拿 canonical 房间。没有复制第二份身份解析（源码合同测试断言全仓只有 1 处调用）。
- 通话页展示信息同样取自权威联系人，杜绝「房间用新身份、页面显示旧资料」。
- 未改：`calls.start` 的媒体/信令实现、`CallController`、`CallPage`、WebRTC/TURN/ICE。
- `ensureCurrentFriendIdentity` 仍服务于「接受好友后建会话」路径（矩阵索引契约不变）。

## 11–13. 测试（新增 19 项，全部通过）

| 测试文件 | 数量 | 覆盖 |
| --- | --- | --- |
| `test/features/matrix/room_navigation_coordinator_test.dart` | 11 | Test 1 单租约单页面；Test 2 Room A → 资料 → 打开 A 回到原页面（不叠加）；Test 3 并发两次只一次租约/push（`identical` 复用 future）；Test 4 A→B 正常打开；Test 5 A→B→A `popUntil(A)` 不产生第三层且 B 释放登记；Test 6 退出清理+可重开；Test 7 打开抛异常→登记/opening 清理后可重开；Test 8 dispose/clear 不泄漏到下一个账号；Test 9 A 的租约取消不阻塞 B；Test 10 取消期间重开 A 新开页面；附加：`onRoomReady/onRoomClosed` 与 push 顺序 |
| `test/features/matrix/matrix_home_room_delegation_test.dart` | 3 | 消息列表委托统一入口（roomId/roomName 正确、自己不建 RoomPage、`onRoomReady` 置已读、退出恢复）；同房间连点只委托一次、退出后可再打开；`previewOnly` 占位页不打开房间 |
| `test/features/matrix/call_entry_identity_test.dart` | 3 | Test A 语音：入口 OLD、目录 NEW ⇒ `directChats.open(NEW)`、canonical 房间；Test B 视频：同一解析（且全仓只解析一次）；Test C 通话页展示取权威联系人（备注/昵称/头像），`calls.start` 用权威 matrixUserId、不再出现 `contact.matrixUserId` |
| `test/features/matrix/profile_message_route_wiring_test.dart` | 5 | AppHome 只有一个 RoomPage 构建点且保留 onMessage/onVoice/onVideo；消息列表无 RoomPage/openRoomLease/setOnRevoked 且按 roomId 去重；协调器接线与 dispose 清理；阶段一的好友入口约束仍在；canonical 网关未被绕过 |
| `test/features/matrix/direct_chat_service_test.dart`（改写源码合同） | 9 | 「打开聊天先 push 再后台预热」在**新架构**下仍成立：列表侧与 AppHome 打开流程都不串行 await 身份预载，租约仍先取后 push |

**未删除任何既有测试**；因架构变化改写了 1 个源码合同测试（`direct_chat_service_test` 的
「打开聊天先 push 再后台预热」）与 1 个接线测试，语义均保留并加强。

变异探针（改动后复原，证明新测试有鉴别力）：

| 变异 | 结果 |
| --- | --- |
| 协调器先判 `_opening` 再判 `_active` | Test 2/Test 5 转红（叠加第二层 / 不 pop） |
| 去掉 `register` 里的 `_opening.remove` | Test 10 转红（取消期间重开变成静默无操作） |
| 先启动流程再登记 opening | Test 10 转红（同上，opening 永远不清理） |
| `_openCall` 改回 `contact.matrixUserId` | Test A/B/C 转红（源码合同与解析断言） |

## 14. flutter analyze

`flutter analyze`（全量）→ 退出码 0，`No issues found!`。

## 15. flutter test

- 受影响面（matrix + contacts + app_home_lifecycle + finance/redpacket/transfer）→ 全部通过
  （日志 `artifacts/2026-09-17/stage2-affected-tests.txt`）。
- 全量 `flutter test` → 退出码 0，**2740 通过 / 0 失败**（阶段一 2721，本阶段 +19）。
  日志 `artifacts/2026-09-17/flutter-full-stage2-room-navigation.txt`。
- `dart format`：新增/改写的 4 个新文件 format-clean；对 `app_home.dart` /
  `matrix_home_page.dart` 运行 format 会重排**编辑区域所在**代码的缩进（tall style，纯空白，
  测试与 analyze 均通过）；仓库既有文件本身并非 format-clean，故未对无关文件做全仓重排
  （唯一一处与本任务无关的重排已手工还原）。

## 16. 仍保留的 legacy RoomPage 入口

**无。** 生产代码中 `builder: (_) => RoomPage(` 只有 1 处，即协调器的统一打开流程；
消息列表、通知、地址簿、建群后、好友资料全部经由它。仍属「各入口自有」的只有列表侧的
展示/已读职责（overlay、`_warmChatIdentity`、`ConversationReadState`、`markReadOnOpen`），
这是刻意保留的（见第 4 节）。通话入口不是 RoomPage，未纳入本阶段的导航协调器。

## 17. Remaining Risks

1. `RoomPage` 打开流程 `await Navigator.push(route)`，因此 `coordinator.open()` 的 future 在
   **页面关闭**时完成；所有等待它的调用方（列表 `_openRoom`、`_openMessage` 的
   `DirectMessageOpenGate`）都会把各自的局部状态持有到页面关闭。这是既有语义（旧的
   `_openManagedRoom` 也 await push），已在文档与测试中固定。
2. 协调器状态是内存态：AppHome `dispose()`/`clear()` 会清空；MatrixHomePage 自身的
   `_openingRooms` 随 widget 生命周期释放。账号切换依赖 `SessionGate` 重建 AppHome
   （既有机制），本阶段未改会话逻辑。
3. 测试用假租约（只统计取租/取消次数）验证导航语义；**真实 MatrixRoomLease 的 revoke 时序、
   账号切换取消、真机 6 秒 drain 未在设备上验证**（用户要求本次不真机测试）。
4. 建群后打开新群现在走统一流程，revoke 实现由「`removeRoute` + `await route.popped`」变为
   「`popUntil` 自身 + 当前则 pop」；两者都只关闭该房间页，但这是本阶段唯一一处**行为有微调**
   的既有路径，建议真机回归一次「建群 → 退出群聊」。
5. `_openConversationFromNotification` 仍是独立入口（自带 `waitForRoom` 超时），只是复用
   `_openManagedRoom`；未做零风险接入改造（用户允许保留并审计）。
6. 唯一一处与本任务无关的格式化重排已还原；若后续有人在 `app_home.dart` /
   `matrix_home_page.dart` 上跑全文件 `dart format`，会产生大量空白 diff（仓库现状如此）。
