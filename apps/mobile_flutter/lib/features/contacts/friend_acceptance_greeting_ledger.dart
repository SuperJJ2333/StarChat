import 'package:shared_preferences/shared_preferences.dart';

import '../matrix/matrix_room_timeline_adapter.dart';

/// 好友接受招呼的幂等键：与 Matrix 发送事务 id 同源（同一个一次性记录）。
///
/// 申请 id 由业务 API `/friends/requests` 返回，是服务端权威的一次性记录：
/// 同一段好友关系永远只有这一个 id（重复申请会产生新 id），因此
/// `friend-accepted-request-<requestId>` 可以同时作为
/// - 本地「已发放过招呼」的持久化幂等键；
/// - `MatrixSdkE2eeClient.sendFriendAccepted` 的事务 id（服务端去重）。
///
/// 申请 id 缺失（旧服务端）时退回 `friend-accepted-<roomId>-<acceptingUserId>`，
/// 与 `friendAcceptedTransactionId` 的回退规则逐字一致。
String friendAcceptanceGreetingKey({
  String? requestId,
  required String roomId,
  required String acceptingUserId,
}) =>
    friendAcceptedTransactionId(
      roomId: roomId,
      acceptingUserId: acceptingUserId,
      requestId: requestId,
    );

/// 好友接受招呼（`com.changliao.friend_accepted` 系统提示 + 好友申请说明／
/// 打招呼）的**一次性发放账本**。
///
/// ## 缺陷（2026-09-19 复现）
/// 「通过朋友验证」页每次点击「打开聊天」都会走
/// `FriendRequestsPage._openAcceptedRequest` → `FriendAcceptanceCoordinator`
/// → `AppHome._establishDirectChatAndGreet`，后者**无条件**调用
/// `MatrixSdkE2eeClient.sendFriendAccepted`，于是每点一次会话里就多出一条
/// 「你们已成为好友，现在可以开始聊天了。」和一次好友申请说明。
///
/// ## 为什么不能用内存 bool
/// 事务 id 虽然稳定，但 Matrix 客户端/服务端的 txid 去重只覆盖有限的时间窗口，
/// 进程重启或缓存过期后仍会重复投递；内存 bool 同样在重启后失效。本账本把
/// 「该一次性记录是否已经发放」持久化到 `SharedPreferences`：
///
/// - 幂等键 = 服务端权威的好友申请 id（见 [friendAcceptanceGreetingKey]）；
/// - 按账号（[accountKey]，Matrix 用户 id）分区，换账号登录不会误判；
/// - 先 [claim] 占位（原子认领）再发送：并发/重复点击只有一次能得到 `true`；
/// - 发送失败调用 [release] 释放占位，下一次重试仍能补发（不会丢系统提示）；
/// - 记录有界（[maxEntries]），只保留最近的记录，不会无限增长。
///
/// 调用顺序（修复建议见 `docs/verification/2026-09-19-friend-acceptance-greeting-idempotency.md`）：
/// ```dart
/// final reference = await directChats.open(matrixUserId); // 每次都打开会话
/// final key = friendAcceptanceGreetingKey(
///     requestId: request['id']?.toString(),
///     roomId: reference.roomId,
///     acceptingUserId: widget.matrix.userId ?? '');
/// if (await ledger.claim(key)) {
///   try {
///     await widget.matrix.sendFriendAccepted(...);
///   } catch (_) {
///     await ledger.release(key); // 失败释放，重试可补发
///     rethrow;
///   }
/// }
/// await _openConversationFromNotification(reference.roomId, ...);
/// ```
final class FriendAcceptanceGreetingLedger {
  FriendAcceptanceGreetingLedger({
    required this.preferences,
    required this.accountKey,
  });

  /// 每个账号最多保留的记录条数（超出的最旧记录被淘汰）。
  static const maxEntries = 200;

  /// 账号分区的持久化键。
  static String storageKey(String accountKey) =>
      'friend-acceptance-greeted-v1:$accountKey';

  final SharedPreferences preferences;
  final String accountKey;

  String get _key => storageKey(accountKey);

  List<String> _entries() => preferences.getStringList(_key) ?? const [];

  /// 该一次性记录是否已经发放过。
  Future<bool> greeted(String key) async => _entries().contains(key.trim());

  /// 认领一次发放权：首次返回 `true` 并立即落盘（进程重启后仍是 `false`），
  /// 重复认领返回 `false`。发送失败必须 [release] 释放。
  Future<bool> claim(String key) async {
    final id = key.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(
          key, 'key', '幂等键不能为空：无法区分不同好友的接受招呼');
    }
    final entries = List<String>.of(_entries());
    if (entries.contains(id)) return false;
    entries.add(id);
    if (entries.length > maxEntries) {
      entries.removeRange(0, entries.length - maxEntries);
    }
    await preferences.setStringList(_key, entries);
    return true;
  }

  /// 释放认领（发送失败时调用），让下一次重试还能补发。
  Future<void> release(String key) async {
    final id = key.trim();
    final entries = List<String>.of(_entries());
    if (!entries.remove(id)) return;
    await preferences.setStringList(_key, entries);
  }
}
