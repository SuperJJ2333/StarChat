# 缺陷 3 收口（app_home 侧）：「打开聊天」不再重复发放好友接受系统提示

**日期：** 2026-09-19
**改动文件：** `apps/mobile_flutter/lib/app_home.dart`（本线拥有）
**上游设计文档：** `docs/verification/2026-09-19-friend-acceptance-greeting-idempotency.md`（UI 线提供，本文不修改）
**幂等账本：** `apps/mobile_flutter/lib/features/contacts/friend_acceptance_greeting_ledger.dart`（UI 线交付，直接复用，未改动）

## 1. 应用的最小改法

`_establishDirectChatAndGreet` 的可见行为拆成两件互不影响的事：

- **打开会话：每次都执行**（`ensureCurrentFriendIdentity` → `directChats.open` →
  `_openConversationFromNotification`），与修复前逐字一致；
- **一次性系统提示 + 打招呼：由持久化账本门控**，只有
  `FriendAcceptanceGreetingLedger.claim(greetingKey)` 认领成功才调用
  `widget.matrix.sendFriendAccepted(...)`；发送失败 `release` 释放认领并向上抛，
  让既有的"失败弹窗 + 重试"编排保持可补发。

`greetingKey` 直接用 UI 线交付的 `friendAcceptanceGreetingKey(...)`（内部委托
`friendAcceptedTransactionId`），因此本地账本键与 Matrix 发送事务 id **逐字一致**：

- 有申请 id：`friend-accepted-request-<requestId>`（服务端权威一次性记录）；
- 无申请 id：`friend-accepted-<roomId>-<acceptingUserId>`（与 txid 回退规则一致）。

账本实例在 AppHome 生命周期内**只建一次**并复用（`_greetingLedgerInstance`，
账号变化时按新账号重建），挂载在 `SharedPreferences` 上，所以进程重启后仍记得
"已经发放过"。

为了可测且不把编排逻辑埋进 `State`，实际门控逻辑抽成顶层函数
`establishAcceptedFriendChat(...)`（仍在 `lib/app_home.dart`）：

```dart
Future<void> establishAcceptedFriendChat({
  required FriendAcceptanceGreetingLedger ledger,
  required String acceptingUserId,
  required String? requestId,
  required Future<String> Function() openRoom,
  required Future<void> Function(String roomId) sendGreeting,
  required Future<void> Function(String roomId) openConversation,
});
```

顺序：`openRoom()` → 计算幂等键 → 进程内同键去重 → `claim` → `sendGreeting`
（失败 `release` + rethrow）→ `openConversation()`。

进程内同键去重（`_greetingClaimsInFlight`）覆盖"极短时间双击"：账本本身是
读-改-写，同帧并发可能都读到"未发放"，这一层保证同一把键只有一个发放流程在跑；
第二个点击照常打开会话。

## 2. 测试（app_home 编排层）

新增 `apps/mobile_flutter/test/features/contacts/friend_acceptance_greeting_orchestration_test.dart`（6 条）：

| 用例 | 断言 |
| --- | --- |
| 连续打开 4 次 | `openRoom`=4、`openConversation`=4、`sendGreeting`=**1** |
| 进程重启（重建 AppHome/账本实例，同一持久化） | 再打开 2 次后 `sendGreeting` 仍为 1 |
| 首次发送失败 | 抛出、不打开会话（与修复前一致）；重试补发 1 次；之后不再重复 |
| 同记录并发双击 | `sendGreeting`=1、`openConversation`=2 |
| 不同 `requestId` | 各自发放一次（`['req-a','req-b']`） |
| 申请 id 缺失 | 退回 `friend-accepted-!dm:test-@me:test` 键，仍然幂等 |

UI 线账本单测（7 条）继续覆盖账本自身语义，未改动。

红→绿：把门控短路成"总是发送"（`gateAvailable = false`）后运行本文件 →
`00:00 +0 -6: Some tests failed`（6 条全部因发放次数断言失败，实际次数分别为
4/3/3/2/「req-a 重复」/2）；恢复实现 → `00:00 +6: All tests passed!`。

聚焦门禁（真实输出）：

| 命令 | 结果 |
| --- | --- |
| `C:/src/flutter/bin/flutter.bat test test/features/contacts test/features/matrix` | `00:51 +1793: All tests passed!` |
| `C:/src/flutter/bin/flutter.bat analyze`（本线文件范围 + 本文件相关测试） | `No issues found!` |

注意：编排函数刻意放在 `lib/core/friend_acceptance_greeting_flow.dart`（本线拥有）
而不是 `app_home.dart` 内部，`app_home.dart` 只做接线。原因是 `app_home.dart`
的依赖图覆盖几乎整个 App：把它 import 进测试会让本用例在**任何**无关文件处于
编辑中间态时无法编译（本次实测：并发钱包重构期间 `lib/features/wallet/manual_wallet_page.dart`
语法不完整导致 import `app_home.dart` 的测试全部 `Compilation failed`）。
抽到 core 后本用例只依赖账本与其 Matrix 常量，稳定可跑，且 `AppHome` 执行的
仍是同一份实现。

## 3. 剩余风险（不由本文件解决）

1. **认领先于发送**：进程恰好在 `claim` 与 `sendFriendAccepted` 之间被杀时，认领
   已落盘而消息未发出 → 该一次性系统提示不会补发。这是"至多一次"换取"不重复"的
   取舍（与用户诉求一致：重复发放才是被报告的缺陷）。
2. **多端**：本地账本按设备分区，换设备后本地为空，可能再发一次。纵深防御建议
   （需 matrix 拥有者实施，见上游文档 §5）：`sendFriendAccepted` 发送前在本地事件表/
   时间线里查同 txid（或 `content['request_id']`）的事件，命中则直接返回。
3. **同一好友重复申请**：服务端会产生新的申请 id（新的一次性记录），因此会再次
   发放一次系统提示——符合"每一次接受"的语义，不属于缺陷。
