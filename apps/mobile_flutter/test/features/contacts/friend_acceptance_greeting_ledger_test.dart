import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/friend_acceptance_greeting_ledger.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_room_timeline_adapter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 缺陷 3（2026-09-19）：接受好友后的「你们已成为好友…」系统提示与申请说明
/// （打招呼）必须**幂等**——同一好友重复点击「打开聊天」/重复进入都只产生一次，
/// 且进程重启后仍然只产生一次（禁止内存 bool）。
///
/// 根因：`AppHome._establishDirectChatAndGreet` 每次都无条件调用
/// `MatrixSdkE2eeClient.sendFriendAccepted`；进入点
/// `FriendRequestsPage._openAcceptedRequest` 每次点击都会走到它。
///
/// 本测试锁定幂等账本的契约（认领 / 落盘 / 失败释放 / 账号隔离 / 有界），
/// 以及把账本按修复建议接到发放点后的可见行为：打开会话每次都会执行，
/// 系统提示与打招呼只发放一次。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('同一申请只允许认领一次，重复认领返回 false', () async {
    final prefs = await SharedPreferences.getInstance();
    final ledger = FriendAcceptanceGreetingLedger(
        preferences: prefs, accountKey: 'matrix:@me:test');

    expect(await ledger.claim('friend-accepted-request-r1'), isTrue,
        reason: '首次发放必须被认领');
    expect(await ledger.claim('friend-accepted-request-r1'), isFalse,
        reason: '同一好友同一申请不得第二次发放');
    expect(await ledger.greeted('friend-accepted-request-r1'), isTrue);

    expect(await ledger.claim('friend-accepted-request-r2'), isTrue,
        reason: '另一位好友（新的申请 id）必须能正常发放');
  });

  test('发送失败可释放认领，重试仍能补发（且只补发一次）', () async {
    final prefs = await SharedPreferences.getInstance();
    final ledger = FriendAcceptanceGreetingLedger(
        preferences: prefs, accountKey: 'matrix:@me:test');

    expect(await ledger.claim('friend-accepted-request-r1'), isTrue);
    await ledger.release('friend-accepted-request-r1');
    expect(await ledger.greeted('friend-accepted-request-r1'), isFalse,
        reason: '失败释放后必须回到未发放状态');
    expect(await ledger.claim('friend-accepted-request-r1'), isTrue,
        reason: '失败后重试必须还能补发');
    expect(await ledger.claim('friend-accepted-request-r1'), isFalse);
  });

  test('进程重启后仍判定为已发放（持久化，不是内存 bool）', () async {
    final prefs = await SharedPreferences.getInstance();
    final first = FriendAcceptanceGreetingLedger(
        preferences: prefs, accountKey: 'matrix:@me:test');
    expect(await first.claim('friend-accepted-request-r1'), isTrue);

    // 模拟进程重启：同一份持久化存储上重新构造账本。
    final restarted = FriendAcceptanceGreetingLedger(
        preferences: prefs, accountKey: 'matrix:@me:test');
    expect(await restarted.claim('friend-accepted-request-r1'), isFalse,
        reason: '重启后重复进入/重复点击不得再次发放');
  });

  test('不同账号分区，互不误判', () async {
    final prefs = await SharedPreferences.getInstance();
    final alice = FriendAcceptanceGreetingLedger(
        preferences: prefs, accountKey: 'matrix:@alice:test');
    final bob = FriendAcceptanceGreetingLedger(
        preferences: prefs, accountKey: 'matrix:@bob:test');

    expect(await alice.claim('friend-accepted-request-r1'), isTrue);
    expect(await bob.claim('friend-accepted-request-r1'), isTrue,
        reason: '换账号登录不得共用同一个发放记录');
  });

  test('记录有界：只保留最近的 N 条，最旧的可被淘汰', () async {
    final prefs = await SharedPreferences.getInstance();
    final ledger = FriendAcceptanceGreetingLedger(
        preferences: prefs, accountKey: 'matrix:@me:test');

    for (var i = 0; i < FriendAcceptanceGreetingLedger.maxEntries + 5; i++) {
      expect(await ledger.claim('friend-accepted-request-$i'), isTrue);
    }
    final stored = prefs.getStringList(
        FriendAcceptanceGreetingLedger.storageKey('matrix:@me:test'));
    expect(stored, isNotNull);
    expect(stored!.length, FriendAcceptanceGreetingLedger.maxEntries,
        reason: '账本必须有界，不能无限增长');
    expect(stored.last,
        'friend-accepted-request-${FriendAcceptanceGreetingLedger.maxEntries + 4}',
        reason: '保留的应该是最近的记录');
  });

  test('幂等键与 Matrix 事务 id 同源（同一一次性记录）', () {
    // 有申请 id：`friend-accepted-request-<id>`。
    expect(
        friendAcceptanceGreetingKey(
            requestId: 'r1', roomId: '!room:test', acceptingUserId: '@me:test'),
        friendAcceptedTransactionId(
            roomId: '!room:test',
            acceptingUserId: '@me:test',
            requestId: 'r1'));
    // 任何输入（含空白 id）都必须与发送方使用的事务 id 逐字一致，
    // 否则服务端去重与本地账本会各算一套。
    for (final requestId in <String?>[null, '', '  ', 'r2']) {
      expect(
          friendAcceptanceGreetingKey(
              requestId: requestId,
              roomId: '!room:test',
              acceptingUserId: '@me:test'),
          friendAcceptedTransactionId(
              roomId: '!room:test',
              acceptingUserId: '@me:test',
              requestId: requestId),
          reason: 'requestId=$requestId 时幂等键必须与事务 id 一致');
    }
    expect(
        friendAcceptanceGreetingKey(
            roomId: '!room:test', acceptingUserId: '@me:test'),
        'friend-accepted-!room:test-@me:test');
  });

  test('接到发放点后：重复打开只发放一次（含重启后再次打开）', () async {
    final prefs = await SharedPreferences.getInstance();
    var opened = 0;
    var sent = 0;

    /// 修复建议里 `AppHome._establishDirectChatAndGreet` 的最小改法：
    /// 打开/取得私聊每次都执行，系统提示只在账本认领成功时发送。
    Future<void> establishAndGreet(
        FriendAcceptanceGreetingLedger ledger, String key) async {
      opened++; // directChats.open(matrixUserId) 每次都要打开会话
      if (!await ledger.claim(key)) return; // 已发放 → 只打开，不重发
      sent++;
    }

    final key = friendAcceptanceGreetingKey(
        requestId: 'r1', roomId: '!room:test', acceptingUserId: '@me:test');
    final ledger = FriendAcceptanceGreetingLedger(
        preferences: prefs, accountKey: 'matrix:@me:test');

    await establishAndGreet(ledger, key); // 通过验证后的首次编排
    await establishAndGreet(ledger, key); // 再次点击「打开聊天」
    await establishAndGreet(ledger, key); // 再次进入后第三次点击

    // 进程重启后再次进入该页并点击「打开聊天」。
    final restarted = FriendAcceptanceGreetingLedger(
        preferences: prefs, accountKey: 'matrix:@me:test');
    await establishAndGreet(restarted, key);

    expect(opened, 4, reason: '每次点击都必须打开会话');
    expect(sent, 1, reason: '系统提示与打招呼只能出现一次');
  });
}
