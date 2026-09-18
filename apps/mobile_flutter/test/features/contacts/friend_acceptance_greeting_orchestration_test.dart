import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/friend_acceptance_greeting_flow.dart';
import 'package:liuhetong_mobile/features/contacts/friend_acceptance_greeting_ledger.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// BUG-3 编排层用例（组合根 `lib/app_home.dart` 实际执行的同一条路径）：
/// 「打开聊天」重复点击/进程重启不得重复发放好友接受系统提示与打招呼，
/// 但**打开会话本身每次都执行**（既有行为不变）。
///
/// 编排函数 `establishAcceptedFriendChat` 是 `AppHome` 调用的同一份实现
/// （抽到 `lib/core/friend_acceptance_greeting_flow.dart` 以便稳定测试：
/// 不依赖 AppHome 的整棵 widget 依赖图）。
/// 账本本身的单测在 test/features/contacts/friend_acceptance_greeting_ledger_test.dart
/// （UI 线提供），这里只验证组合根编排：认领→发送→失败释放→每次打开会话。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences preferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    preferences = await SharedPreferences.getInstance();
  });

  FriendAcceptanceGreetingLedger newLedger() => FriendAcceptanceGreetingLedger(
        preferences: preferences,
        accountKey: 'matrix:@me:test',
      );

  test('连续打开 4 次 → 打开 4 次、发放 1 次', () async {
    final ledger = newLedger();
    var opens = 0;
    var conversations = 0;
    var greetings = 0;

    for (var i = 0; i < 4; i++) {
      await establishAcceptedFriendChat(
        ledger: ledger,
        acceptingUserId: '@me:test',
        requestId: 'req-1',
        openRoom: () async {
          opens++;
          return '!dm:test';
        },
        sendGreeting: (roomId) async {
          greetings++;
          expect(roomId, '!dm:test');
        },
        openConversation: (roomId) async => conversations++,
      );
    }

    expect(opens, 4, reason: '每次点击都必须解析/打开会话');
    expect(conversations, 4, reason: '每次点击都必须进入会话（行为不变）');
    expect(greetings, 1, reason: '一次性系统提示只发放一次');
  });

  test('进程重启（重建账本实例，同一持久化）后仍只发放一次', () async {
    var greetings = 0;
    Future<void> run(FriendAcceptanceGreetingLedger ledger) =>
        establishAcceptedFriendChat(
          ledger: ledger,
          acceptingUserId: '@me:test',
          requestId: 'req-restart',
          openRoom: () async => '!dm:test',
          sendGreeting: (roomId) async => greetings++,
          openConversation: (roomId) async {},
        );

    await run(newLedger());
    expect(greetings, 1);

    // 模拟杀进程重开：全新 AppHome + 全新账本实例，只有 SharedPreferences 留存。
    await run(newLedger());
    await run(newLedger());
    expect(greetings, 1, reason: '持久化账本让重启后也不再发放');
  });

  test('首次发送失败 release 后可补发一次，之后不再重复', () async {
    final ledger = newLedger();
    var attempts = 0;
    var openedAfterFailure = 0;
    var conversations = 0;

    Future<void> invoke() => establishAcceptedFriendChat(
          ledger: ledger,
          acceptingUserId: '@me:test',
          requestId: 'req-retry',
          openRoom: () async => '!dm:test',
          sendGreeting: (roomId) async {
            attempts++;
            if (attempts == 1) throw StateError('offline');
          },
          openConversation: (roomId) async {
            conversations++;
            if (attempts == 1) openedAfterFailure++;
          },
        );

    await expectLater(invoke(), throwsStateError);
    expect(attempts, 1);
    expect(openedAfterFailure, 0);
    expect(conversations, 0,
        reason: '发送失败向上抛出：由既有的失败弹窗 + 重试编排处理（与修复前一致）');

    // 用户重试：认领已被释放，因此可以补发一次。
    await invoke();
    expect(attempts, 2);
    expect(conversations, 1);

    // 之后继续点击不再发送。
    await invoke();
    expect(attempts, 2, reason: '补发成功后重新被账本门控');
    expect(conversations, 2);
  });

  test('同一记录并发（极短时间双击）只发放一次，两次都打开会话', () async {
    final ledger = newLedger();
    var greetings = 0;
    var conversations = 0;
    final gate = Completer<void>();

    Future<void> invoke() => establishAcceptedFriendChat(
          ledger: ledger,
          acceptingUserId: '@me:test',
          requestId: 'req-double-tap',
          openRoom: () async => '!dm:test',
          sendGreeting: (roomId) async {
            greetings++;
            await gate.future;
          },
          openConversation: (roomId) async => conversations++,
        );

    final first = invoke();
    final second = invoke();
    gate.complete();
    await Future.wait(<Future<void>>[first, second]);

    expect(greetings, 1, reason: '并发点击也不得重复发放');
    expect(conversations, 2, reason: '两次点击都要进入会话');
  });

  test('不同好友申请（不同 requestId）各自发放一次', () async {
    final ledger = newLedger();
    final sent = <String>[];

    Future<void> greet(String requestId) => establishAcceptedFriendChat(
          ledger: ledger,
          acceptingUserId: '@me:test',
          requestId: requestId,
          openRoom: () async => '!dm:test',
          sendGreeting: (roomId) async => sent.add(requestId),
          openConversation: (roomId) async {},
        );

    await greet('req-a');
    await greet('req-a');
    await greet('req-b');

    expect(sent, <String>['req-a', 'req-b']);
  });

  test('申请 id 缺失（旧服务端）时退回房间+账号键，仍然幂等', () async {
    final ledger = newLedger();
    var greetings = 0;

    Future<void> invoke() => establishAcceptedFriendChat(
          ledger: ledger,
          acceptingUserId: '@me:test',
          requestId: null,
          openRoom: () async => '!dm:test',
          sendGreeting: (roomId) async => greetings++,
          openConversation: (roomId) async {},
        );

    await invoke();
    await invoke();

    expect(greetings, 1);
    expect(await ledger.greeted('friend-accepted-!dm:test-@me:test'), isTrue);
  });
}
