# 根因与验证：DirectMessageOpenGate 生命周期边界修复（Room A 内再次「发消息」无反应）

- 日期：2026-09-17（Asia/Hong_Kong）
- 工作树：`D:\pythonProject\outsource\StarChat`（主工作树，Flutter app：`apps/mobile_flutter`）
- 范围：只修 `DirectMessageOpenGate` 的**锁定范围**与 `AppHome._openMessage` 的命中边界；
  未改 `RoomNavigationCoordinator` 状态机语义、`DirectChatController`、`CoordinatedDirectChatGateway`、
  canonical room 仲裁、`MatrixRoomLease`、E2EE、通话/群聊/朋友圈/通知/登录。
- 用户要求：不 pull、不真机测试、不构建 APK/IPA、不部署。

## 1. 真机复现（用户原述）

```text
通讯录 → 好友 A → 好友资料 → 发消息 → Room A → 再进入好友资料 → 再点击「发消息」
```

第二次点击「发消息」**完全没反应**（无页面、无报错、无任何反馈）。

## 2. 根因（代码级）

`_AppHomeState._openMessage` 旧实现把整个打开流程放进 `DirectMessageOpenGate`：

```dart
if (!_directMessageGate.claim(openingKey)) return;      // 认领
try {
  final authoritative = await resolveFriendContact(cache, contact);
  final reference = await directChats.open(authoritative.matrixUserId.trim());
  await _openManagedRoom(reference.roomId, ...);         // ← await 到 RoomPage 关闭才完成
} finally {
  _directMessageGate.release(openingKey);                // ← 因此闸门一直持有到页面关闭
}
```

`RoomNavigationCoordinator._openManagedRoomRoute` 以 `await navigator.push(route)` 结束，
该 Future 只在 **RoomPage 被 pop 之后** 完成。于是：

```text
Room A 已打开（闸门仍认为好友 A 正在 opening）
→ 好友资料 → 再点「发消息」
→ _directMessageGate.claim('bob') == false
→ _openMessage 直接 return（静默丢弃）
→ 请求根本到不了 RoomNavigationCoordinator
→ 无法执行 popUntil(existing Room A)
```

关键点：`RoomNavigationCoordinator` 的「已打开 → popUntil」分支本身是正确的（阶段二已验证），
只是第二次请求在到达它之前就被上游闸门吞掉了。**两个组件重复管理了「页面是否打开」**。

## 3. 修复

### 3.1 缩小闸门锁定范围

```dart
Future<void> _openMessage(ContactDetails contact) async {
  try {
    final target = await _directMessageGate.run(
      directMessageOpenKey(contact),
      () => _resolveDirectMessageTarget(contact),   // 闸门内：身份 + canonical roomId
    );
    if (!mounted) return;
    await _openManagedRoom(                        // 闸门外：push/复用/popUntil + 租约
      target.roomId,
      roomName: target.contact.displayName,
      initialContact: target.contact,
    );
  } catch (error) {
    if (!mounted) return;
    await showDirectChatFailureDialog(context, error,
        onRetry: () => _openMessage(contact));
  }
}

Future<DirectMessageTarget> _resolveDirectMessageTarget(ContactDetails contact) async {
  final cache = await _identityCache();
  final authoritative = await resolveFriendContact(cache, contact);   // 权威身份不变
  final matrixUserId = authoritative.matrixUserId.trim();
  if (matrixUserId.isEmpty) {
    throw StateError('The contact is no longer a current friend');
  }
  final reference = await directChats.open(matrixUserId);
  return DirectMessageTarget(roomId: reference.roomId, contact: authoritative);
}
```

### 3.2 新增 `DirectMessageTarget`（类型安全的数据载体）

`lib/features/matrix/direct_chat_entry.dart`：

```dart
final class DirectMessageTarget {
  const DirectMessageTarget({required this.roomId, required this.contact});
  final String roomId;              // canonical 私聊房间
  final ContactDetails contact;     // 权威联系人（含补齐/更新后的 matrixUserId）
}
```

- **未**包含 `cache`：`_openManagedRoom` 不接受 cache 参数，账号级仓库由 AppHome 的
  `_identityCache()` 自己幂等获取；加一个用不到的字段只会制造死代码。
- **不含** `BuildContext` / `Navigator` / `Route` / `RoomLease`（与
  `RoomOpenRequest` 同样的纪律）。

### 3.3 闸门改为真正的 single-flight（返回同一个 Future）

```dart
Future<DirectMessageTarget> run(String key, Future<DirectMessageTarget> Function() operation) {
  if (key.isEmpty) return operation();                 // 空键（身份未知）不参与去重
  final existing = _flights[key];
  if (existing != null) return existing;               // 复用同一个 flight（不再静默丢弃）
  final completer = Completer<DirectMessageTarget>();
  final pending = completer.future;
  _flights[key] = pending;                             // 先占位再启动，避免同帧第二次点击漏合并
  unawaited(Future<DirectMessageTarget>.sync(operation).then((target) {
    if (identical(_flights[key], pending)) _flights.remove(key);   // 成功即释放
    if (!completer.isCompleted) completer.complete(target);
  }, onError: (Object error, StackTrace stackTrace) {
    if (identical(_flights[key], pending)) _flights.remove(key);   // 失败同样释放（重试可用）
    if (!completer.isCompleted) completer.completeError(error, stackTrace);
  }));
  return pending;
}
```

- 旧 API 是 `claim/release` + 「已有 opening → return / no-op」；新 API 是
  `run(key, operation)` + 「已有 opening → 返回同一个 Future」。
- 无 `existing as Future<T>` 之类不安全泛型转换：`_flights` 就是
  `Map<String, Future<DirectMessageTarget>>`，类型在闸门内固定。
- 释放时机由「页面关闭」变成「canonical roomId 解析完成 / 解析失败」，与
  `RoomNavigationCoordinator` 的 roomId 级去重不再重叠。

### 3.4 修复后调用链

```text
ContactProfilePage
→ AppHome._openMessage
→ DirectMessageOpenGate.run（只锁这一段）
   → resolveFriendContact（业务 userId → 权威 ContactDetails）
   → directChats.open(authoritative.matrixUserId)  → canonical roomId
   → return DirectMessageTarget
→ 【Gate released】
→ _openManagedRoom → RoomNavigationCoordinator.open(roomId)
   ├ 已打开 → popUntil(existing Room)
   ├ 正在打开 → 复用 opening
   └ 未打开 → 取租约 + push RoomPage
```

## 4. 未改动项（职责是否保持）

| 组件 | 是否改动 | 说明 |
| --- | --- | --- |
| `RoomNavigationCoordinator` | 未改（0 行） | active 优先 opening、opening single-flight、A→B→A popUntil、revoke/push 失败清理、cancel 不阻塞其它 roomId 全部保留；`open()` 仍是「页面关闭后才完成」 |
| `DirectChatController` / `_openings` | 未改 | |
| `CoordinatedDirectChatGateway` / canonical 仲裁 | 未改 | |
| `MatrixRoomLease` / RoomPage 生命周期 | 未改 | |
| 权威身份解析 `resolveFriendContact` | 未改 | stale Matrix ID 行为保留（新用例 Test 6 覆盖集成路径） |
| E2EE / 通话 / 群聊 / 朋友圈 / 通知 / 登录 | 未改 | |

## 5. 测试

### 5.1 新增：`test/features/matrix/direct_message_open_lifecycle_test.dart`（6 用例，集成级）

穿过真实生产链路：`ContactsTabPage/ContactProfilePage 的 onMessage`（= `AppHome._openMessage`）
→ `DirectMessageOpenGate` → `resolveFriendContact` → `DirectChatController` +
`CoordinatedDirectChatGateway` → `RoomNavigationCoordinator` → `RoomPage` + `MatrixRoomLease`。
只替换传输与缓存：真实 SDK `Client`/`Room`（成员、加密、`m.direct` 用真实状态事件），
Matrix 传输为「一 HTTP 即失败」的 `MockClient`，业务 API 为可路由的 `MockClient`。

| 用例 | 断言 |
| --- | --- |
| Test 1 首次打开 Room A | 1 次 canonical 房间解析（`client.getDirectChatFromUserId` 调用序列 == `['@bob:test']`）、1 个 RoomPage、1 份租约（`debugManagedResourceCount` +1）、0 次 Matrix HTTP |
| Test 2 Room A 内再次「发消息」 | 第二次请求**真的走完**（future 完成）、canonical 解析计数 1→2（到达协调器）、好友资料页被 popUntil 掉、RoomPage 仍只有 1 个、`roomLease` 对象 identical、租约登记数不变 |
| Test 3 页面未关闭时闸门已释放 | Room A 仍 active 时第二次「发消息」重新进入解析（计数 +1），不叠加页面 |
| Test 4 慢身份解析并发两次 | 并发窗口内目录刷新 **1 次**（身份解析只执行一次）、canonical 查找 1 次、1 个 RoomPage、1 份租约、关闭 Room A 后**两个调用都完成**（single-flight 把结果交给两个调用方） |
| Test 5 失败后重试 | `directChats.open` 失败 → 弹窗「无法打开加密会话」+「重试」→ 修好元数据后点重试 → RoomPage 打开、解析计数再 +1（闸门无残留） |
| Test 6 权威 Matrix ID 不回归 | Room A 内第二次请求带 `matrixUserId='@bob:old'` 的过期快照 → 实际 canonical 查找用 `'@bob:test'`（权威值），且请求到达协调器 |

### 5.2 改写：`test/features/matrix/direct_chat_entry_test.dart` 闸门用例（4 个，单元级）

- `同一好友的闸门 single-flight：复用同一个 Future 与目标，解析完成即释放`
  （`identical(first, second)`、同一 `DirectMessageTarget` 实例、操作只执行 1 次、完成后 `isOpen == false`）
- `房间页面仍打开时闸门已释放：同一好友可再次进入解析`（要求 十 的单元级表达）
- `解析失败同样释放闸门，弹窗「重试」可以重新进入`
- `不同好友各自独立，空键不参与去重`

### 5.3 接线断言：`test/features/matrix/profile_message_route_wiring_test.dart`

新增源码结构断言：`_openMessage` 中闸门闭包只能是 `() => _resolveDirectMessageTarget(contact)`、
`await _openManagedRoom(...)` 必须出现在 `_directMessageGate.run(` **之后**、
`_openMessage` 体内不得直接出现 `directChats.open`。

### 5.4 红/绿证据

修复前（旧代码）运行新集成用例：

```text
Test 2 [E] Expected: <2>  Actual: <1>   第二次请求必须到达 RoomNavigationCoordinator（闸门已释放）
Test 3 [E] Expected: <2>  Actual: <1>   canonical 房间获取完成后闸门即释放，页面开着也必须能再次进入
Test 6 [E] Expected: false Actual: <true>  第二次请求必须到达协调器并回到原 Room A
```

即：第二次「发消息」被闸门吞掉、好友资料页没有被 pop、canonical 解析只发生一次——
与真机「完全没反应」一致。修复后 6/6 通过。

### 5.5 变异探针（改动后已复原，`Compare-Object` 差异 0）

| 探针 | 改动 | 结果 |
| --- | --- | --- |
| A：把 `_openManagedRoom` 放回闸门内 | `_openMessage` 的闸门闭包里 `await _openManagedRoom(...)` | Test 2 / Test 3 / Test 6 **转红**（Room A 内再次「发消息」用例） |
| B：闸门遇到已有 flight 时静默吞掉 | `if (existing != null) return Completer<DirectMessageTarget>().future;` | 闸门 single-flight 单元用例 **转红**、集成 Test 4（慢身份解析并发）**转红** |

### 5.6 门禁

- 定向：`direct_chat_entry_test` + `direct_message_open_lifecycle_test` +
  `room_navigation_coordinator_test` + `profile_message_route_wiring_test` +
  `canonical_direct_chat_test` + `coordinated_direct_chat_test` + `direct_chat_controller_test`
  + `test/features/contacts` + `app_home_lifecycle_test` → **162 通过 / 0 失败**。
- `flutter analyze`（全量）→ 退出码 0，`No issues found!`。
- `flutter test`（全量）→ 退出码 0，**2835 通过 / 0 失败**（本任务前 2826；
  +6 新增集成用例与 +3 净增闸门单元用例）。
  日志：`docs/verification/artifacts/2026-09-17/flutter-full-direct-message-gate-lifecycle.txt`。
  工具链：Flutter 3.44.9 stable（revision `6b182d2c75`）/ Dart 3.12.2 / Windows 10.0.19045。

## 6. 未执行项与说明

- 未构建 APK/IPA、未安装真机、未部署（用户明确本次不需要）。
- `dart format`：本仓库基线早于 Dart 3.12 的 tall-style 格式化器，`dart format` 对
  **未改动的 HEAD 版本**文件同样报 `Changed`（实测 `HEAD:lib/app_home.dart`、
  `HEAD:.../direct_chat_entry.dart`、`HEAD:.../direct_chat_entry_test.dart` 全部 `Changed`）。
  因此未执行全量 `dart format`（会产生大面积无关 diff），改为：新增/修改代码人工对齐
  既有风格，且改动文件的新增行不超过 80 列；格式与静态检查以 `flutter analyze` 为准。

## 7. 剩余风险

1. 真机未验证：本修复只在本机集成测试（真实 Navigator/Coordinator/gateway + 假 Matrix 传输）
   验证。真机上 canonical 房间解析若走网络（`findCached` 未命中），闸门会持有到该网络往返
   结束——这是**期望**行为（避免重复请求），但用户在这段时间内的第二次点击仍会被合并为
   同一 flight（有反馈延迟，不会无反应）。
2. `DirectMessageOpenGate` 只按「业务 userId（缺失时 Matrix ID）」去重：同一好友若两个入口
   分别只带旧/新 Matrix ID 但没有业务 userId，会各自解析一次（canonical 房间仍由
   `DirectChatController`/协调器去重，不会出现第二个房间）。
3. 失败飞行若无人监听会产生未处理异步错误：`_openMessage` 始终 await 同一 Future，
   未发现可复现路径；若未来新增调用方需自行 catch。
4. 未真机验证「Room A → 好友资料」在真机上确实是压在根 Navigator（本修复依赖
   `popUntil` 作用于含 RoomPage 的同一 Navigator；资料页入口目前统一用
   `Navigator.of(context, rootNavigator: true)`）。
