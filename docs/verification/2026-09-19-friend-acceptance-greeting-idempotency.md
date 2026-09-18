# 缺陷 3 修复建议：「打开聊天」重复发放好友接受系统提示与打招呼

**日期：** 2026-09-19
**状态：** 待应用（**需由 app_home/matrix 拥有者应用**）
**本文件性质：** 缺陷 3 的生产产生点位于 `lib/app_home.dart`（另有 `lib/features/matrix/matrix_e2ee_client.dart` 的落地实现），这两个文件由 message-outbox 特性负责人持有，本次任务不得直接修改，因此按任务要求提交精确修复建议。客户端幂等账本已在本任务范围内实现并有红→绿测试（见 §4）。

---

## 1. 复现与现象

1. 通过好友验证（`POST /friends/requests/{id}/accept` 成功）→ 会话里出现一次居中的
   「你们已成为好友，现在可以开始聊天了。」系统提示与一次好友申请说明（打招呼）。
2. 回到「新的朋友」→ 该请求显示「已添加」→ 进入「通过朋友验证」页 → 再点「打开聊天」：
   会话里**又**出现一条同样的系统提示 + 一次打招呼；重复点击每次都增加一条。

期望：这两条内容只在**对方同意好友请求的那一刻**产生一次；之后重复进入/重复点击只打开会话，不再产生。

## 2. 根因（file:line）

| 位置 | 代码 | 说明 |
|---|---|---|
| `apps/mobile_flutter/lib/features/contacts/contacts_page.dart:1712` | `_openAcceptedRequest(Map request)` | 「打开聊天」入口：每次点击都会走完整编排 |
| 同上 `:1786` | `_initializeAcceptedRequest(request)` | 失败重试循环，成功即返回 |
| 同上 `:1815` | `_onFriendAccepted(request)` | 组装 `FriendAcceptanceCoordinator` 并调用 `onAccepted` |
| `apps/mobile_flutter/lib/features/friendship/friend_acceptance_coordinator.dart:77` | `await establishWithRequest(matrixUserId, userId ?? '', nickname, Map.unmodifiable(request))` | 每次调用都回调组合根（**无任何"是否已发放"判断**） |
| `apps/mobile_flutter/lib/app_home.dart` 的 `_establishDirectChatAndGreet`（当前 `:1032-1047`，行号随并发 outbox 改动漂移） | `await widget.matrix.sendFriendAccepted(...)` | **真正的产生点**：无条件发送 |
| `apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart:6378-6397` | `sendFriendAccepted` → `room.sendEvent(..., txid: friendAcceptedTransactionId(...))` | 用 txid 发送；Matrix 的 txid 去重只覆盖服务端有限的本地缓存窗口 |
| `apps/mobile_flutter/lib/features/matrix/matrix_room_timeline_adapter.dart:64-71` | `friendAcceptedTransactionId` | txid 已经是确定性的一次性键（`friend-accepted-request-<requestId>`），但**没有任何调用方检查它是否已经存在** |

结论：事务 id 虽然稳定，但「是否已经发放过」这件事**没有任何一处被判断或持久化**，所以每次点击都会走一次
`sendEvent`；Matrix 的 txid 去重不能作为唯一保障（缓存窗口过期、进程重启、多端登录后都会重复投递）。
进入点每次都会重建编辑器状态，因此内存 bool 也不能满足「进程重启后仍只发一次」。

## 3. 最小改法（app_home，约 10 行）

`apps/mobile_flutter/lib/app_home.dart` 的 `_establishDirectChatAndGreet`（当前 `:1032-1047`）当前实现：

```dart
  Future<void> _establishDirectChatAndGreet(
    String matrixUserId,
    String friendDisplayName,
    Map request,
  ) async {
    final cache = await _identityCache();
    await ensureCurrentFriendIdentity(cache, matrixUserId);
    final reference = await directChats.open(matrixUserId);
    await widget.matrix.sendFriendAccepted(
        reference.roomId, matrixUserId, friendDisplayName,
        requestId: request['id']?.toString(),
        requestMessage: request['message']?.toString());
    // The recipient sees request context before this route exposes a composer.
    await _openConversationFromNotification(reference.roomId,
        source: RoomOpenSource.friendAccept);
  }
```

建议改为（**打开会话保持每次都执行，只有一次性系统提示被幂等账本门控**）：

```dart
  Future<void> _establishDirectChatAndGreet(
    String matrixUserId,
    String friendDisplayName,
    Map request,
  ) async {
    final cache = await _identityCache();
    await ensureCurrentFriendIdentity(cache, matrixUserId);
    final reference = await directChats.open(matrixUserId);
    // BUG-3（2026-09-19）：好友接受系统提示 + 打招呼是一次性消息，
    // 幂等键 = 服务端权威的好友申请 id（与发送 txid 同源），持久化账本
    // 保证重复进入/重复点击/进程重启后都只发放一次。
    final preferences = await SharedPreferences.getInstance();
    final ledger = FriendAcceptanceGreetingLedger(
        preferences: preferences, accountKey: widget.matrix.userId ?? '');
    final greetingKey = friendAcceptanceGreetingKey(
      requestId: request['id']?.toString(),
      roomId: reference.roomId,
      acceptingUserId: widget.matrix.userId ?? '',
    );
    if (await ledger.claim(greetingKey)) {
      try {
        await widget.matrix.sendFriendAccepted(
            reference.roomId, matrixUserId, friendDisplayName,
            requestId: request['id']?.toString(),
            requestMessage: request['message']?.toString());
      } catch (_) {
        await ledger.release(greetingKey); // 发送失败释放，重试仍能补发
        rethrow;
      }
    }
    // The recipient sees request context before this route exposes a composer.
    await _openConversationFromNotification(reference.roomId,
        source: RoomOpenSource.friendAccept);
  }
```

新增 import：

```dart
import 'features/contacts/friend_acceptance_greeting_ledger.dart';
```

要点：

- `directChats.open(...)` 与 `_openConversationFromNotification(...)` **不**进门控：重复点击仍然打开会话（现有
  `test/features/contacts/friend_acceptance_retry_test.dart` 断言「打开聊天」必须打开会话，行为保持不变）。
- 失败路径 `release` 后 `rethrow`：与既有「初始化失败弹窗 + 重试」编排一致，重试仍能补发一次。

## 4. 幂等键设计（已实现并测试，位于本任务范围内）

| 组件 | 位置 | 说明 |
|---|---|---|
| 幂等账本 | `apps/mobile_flutter/lib/features/contacts/friend_acceptance_greeting_ledger.dart`（本任务新建） | `FriendAcceptanceGreetingLedger(preferences, accountKey)`：`claim(key)` 原子认领并落盘、`release(key)` 失败释放、`greeted(key)` 只读判断；单账号最多保留 `maxEntries = 200` 条 |
| 幂等键 | 同文件 `friendAcceptanceGreetingKey({requestId, roomId, acceptingUserId})` | **直接委托** `friendAcceptedTransactionId`（`matrix_room_timeline_adapter.dart:64`），保证本地账本键与发送事务 id 逐字一致：`friend-accepted-request-<requestId>`，申请 id 缺失时退回 `friend-accepted-<roomId>-<acceptingUserId>` |

为什么键是权威的：

1. `requestId` 来自业务 API `/friends/requests`，是**服务端权威的一次性记录 id**；同一段好友关系永远只有这一个 id
   （重复申请会产生新 id，因此旧 id 不会再被复用），所以它天然区分「同一位好友这一次接受」。
2. 与发送方使用的 Matrix 事务 id **完全相同**：本地账本与服务端 txid 去重指向同一把键，不存在两套 id 的漂移。
3. 按 `accountKey`（Matrix 用户 id）分区：换账号登录不会把上一个账号的发放记录当成自己的。
4. `SharedPreferences` 落盘：**进程重启后仍然只发一次**（内存 bool 不满足）。

测试（红→绿，`flutter test test/features/contacts/friend_acceptance_greeting_ledger_test.dart`，7 条）：
首次认领成功、重复认领 false、失败释放后可补发、**重启（新建账本实例）后仍判已发放**、账号隔离、记录有界、
幂等键与 `friendAcceptedTransactionId` 逐字一致、以及「重复打开 4 次 → 打开 4 次 / 发放 1 次」的编排级断言。

## 5. 建议的纵深防御（matrix 拥有者可选）

`matrix_e2ee_client.dart:6378 sendFriendAccepted` 可以在发送前用同一把键做一次**服务端权威校验**：

- 在 `room.getTimeline()` / 本地事件表中查找是否已存在
  `type == changliaoFriendAcceptedEventType` 且 `unsigned['transaction_id'] == friendAcceptedTransactionId(...)`
  （或 `content['request_id'] == requestId`）的事件；
- 命中则直接返回，不再 `sendEvent`。

这条检查覆盖「用户换设备后本地账本为空、但房间历史里已有该一次性消息」的场景（此时账本会误判为未发放，导致重发）。
本次不实施（文件归属 app_home/matrix 拥有者），作为建议记录。

## 6. 应用后需要补的测试（建议）

在 app_home 或 contacts 的 widget 测试中，用同一 `matrixUserId` + 同一 `request['id']` 连续调用两次
`_establishDirectChatAndGreet` 等价路径，断言：

- `MatrixAppHomeCapability.sendFriendAccepted` 调用次数 == 1（重复进入/重复点击不再增加）；
- `_openConversationFromNotification`（或 `directChats.open`）调用次数 == 2（每次都打开会话）；
- 新建账本（模拟进程重启）后再调用一次，`sendFriendAccepted` 仍为 1。
