import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/room_navigation_coordinator.dart';

/// 以真实 Navigator 验证 roomId 级导航唯一性：打开流程用假租约 + 简单页面，
/// 只统计「取了几次租约 / push 了几个页面 / 释放了几次」。
///
/// 打开流程与生产一致地 `await Navigator.push(route)`，因此
/// `coordinator.open()` 的 future 在**页面关闭**时才完成；测试中不要
/// 在页面还开着时 await 它。
final class _FakeRoomProcedure {
  int leases = 0;
  final opened = <String>[];
  final closed = <String>[];
  final reopened = <RoomOpenRequest>[];

  /// 模拟慢租约：取租约期间挂住。
  Completer<void>? holdLease;

  /// 模拟慢取消：页面退出后挂住（真机可达 6 秒）。
  Completer<void>? holdCancel;

  /// 模拟 push 阶段异常：登记后抛出且故意不释放登记，
  /// 协调器必须自己兜底清理，不能留下假 active。
  String? leakAndThrowFor;
  String? failBeforeRegisterFor;

  NavigatorState? navigator;

  Future<void> open(RoomOpenRequest request, RoomRouteHandle handle) async {
    leases++;
    opened.add(request.roomId);
    final lease = holdLease;
    if (lease != null) await lease.future;
    if (request.roomId == failBeforeRegisterFor) {
      throw StateError('lease unavailable');
    }
    final route = CupertinoPageRoute<void>(
        builder: (_) => Center(child: Text('room:${request.roomId}')));
    handle.register(route, onReopen: reopened.add);
    request.onRoomReady?.call();
    if (request.roomId == leakAndThrowFor) {
      throw StateError('room open failed');
    }
    try {
      final pushed = navigator!.push(route);
      final previous = handle.replacedRoute;
      if (previous != null && previous.isActive) {
        navigator!.removeRoute(previous);
      }
      await pushed;
    } finally {
      handle.release(route);
      request.onRoomClosed?.call();
      closed.add(request.roomId);
      final cancel = holdCancel;
      if (cancel != null) await cancel.future;
    }
  }
}

Future<NavigatorState> _pumpShell(WidgetTester tester) async {
  await tester
      .pumpWidget(const CupertinoApp(home: Center(child: Text('home'))));
  return tester.state<NavigatorState>(find.byType(Navigator));
}

void main() {
  late _FakeRoomProcedure procedure;
  late RoomNavigationCoordinator coordinator;

  Future<void> setUpCoordinator(WidgetTester tester) async {
    final navigator = await _pumpShell(tester);
    procedure = _FakeRoomProcedure()..navigator = navigator;
    coordinator = RoomNavigationCoordinator(
      openRoom: procedure.open,
      navigatorOf: () => navigator,
    );
  }

  RoomOpenRequest request(String roomId) =>
      RoomOpenRequest(roomId: roomId, roomName: 'room $roomId');

  /// 打开并等待页面动画完成（不等待页面关闭）。
  Future<void> openRoom(WidgetTester tester, String roomId) async {
    unawaited(coordinator.open(request(roomId)));
    await tester.pumpAndSettle();
  }

  testWidgets('Test 1: 消息列表打开 Room A 只建一次租约与一个页面', (tester) async {
    await setUpCoordinator(tester);
    await openRoom(tester, '!a:test');

    expect(procedure.leases, 1);
    expect(procedure.opened, ['!a:test']);
    expect(coordinator.activeRoomIds, ['!a:test']);
    expect(find.text('room:!a:test'), findsOneWidget);
  });

  testWidgets('Test 2: Room A 内再次打开 A 回到原页面，不叠加第二层', (tester) async {
    await setUpCoordinator(tester);
    await openRoom(tester, '!a:test');
    // 模拟 Room A → 好友资料（压一层普通页面）。
    unawaited(procedure.navigator!.push(CupertinoPageRoute<void>(
        builder: (_) => const Center(child: Text('profile')))));
    await tester.pumpAndSettle();
    expect(find.text('profile'), findsOneWidget);

    unawaited(coordinator.open(request('!a:test')));
    await tester.pumpAndSettle();

    expect(procedure.leases, 1, reason: '不得再取第二份租约');
    expect(procedure.opened, ['!a:test']);
    expect(find.text('profile'), findsNothing, reason: '应 pop 回原 Room A');
    expect(find.text('room:!a:test'), findsOneWidget);
  });

  testWidgets('Test 3: 并发两次打开同一房间只取一次租约、只 push 一次', (tester) async {
    await setUpCoordinator(tester);
    procedure.holdLease = Completer<void>();
    final first = coordinator.open(request('!a:test'));
    final second = coordinator.open(request('!a:test'));
    expect(identical(first, second), isTrue, reason: '复用同一个 opening future');
    expect(coordinator.isOpening('!a:test'), isTrue);

    procedure.holdLease!.complete();
    procedure.holdLease = null;
    await tester.pumpAndSettle();

    expect(procedure.leases, 1);
    expect(procedure.opened, ['!a:test']);
    expect(find.text('room:!a:test'), findsOneWidget);
  });
  testWidgets(
      'opening delivers the latest source anchor when its route registers',
      (tester) async {
    await setUpCoordinator(tester);
    procedure.holdLease = Completer<void>();
    final opening = coordinator.open(request('!a:test'));
    coordinator.open(const RoomOpenRequest(
        roomId: '!a:test',
        roomName: 'friend',
        anchorEventId: 'first',
        anchorRoomId: '!old:test'));
    final latest = coordinator.open(const RoomOpenRequest(
        roomId: '!a:test',
        roomName: 'friend',
        anchorEventId: 'latest',
        anchorRoomId: '!older:test'));
    expect(latest, same(opening));
    procedure.holdLease!.complete();
    procedure.holdLease = null;
    await tester.pumpAndSettle();
    expect(procedure.leases, 1);
    expect(procedure.reopened.single.anchorEventId, 'latest');
    expect(procedure.reopened.single.anchorRoomId, '!older:test');
  });
  testWidgets(
      'canonical replacement removes old route only after the new route is ready',
      (tester) async {
    final navigator = await _pumpShell(tester);
    procedure = _FakeRoomProcedure()..navigator = navigator;
    coordinator = RoomNavigationCoordinator(
        openRoom: procedure.open,
        navigatorOf: () => navigator,
        conversationKeyOf: (_) => 'dm:peer');
    await openRoom(tester, '!old:test');
    procedure.holdLease = Completer<void>();
    unawaited(coordinator.open(request('!canonical:test')));
    await tester.pump();
    expect(find.text('room:!old:test'), findsOneWidget);
    procedure.holdLease!.complete();
    procedure.holdLease = null;
    await tester.pumpAndSettle();
    expect(procedure.opened, ['!old:test', '!canonical:test']);
    expect(procedure.closed, ['!old:test']);
    expect(coordinator.activeRoomIds, ['dm:peer']);
    expect(find.text('room:!old:test', skipOffstage: false), findsNothing);
    expect(find.text('room:!canonical:test'), findsOneWidget);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(coordinator.activeRoomIds, isEmpty);
  });
  for (final afterRegister in [false, true]) {
    testWidgets(
        'failed replacement restores original route and callback, afterRegister=$afterRegister',
        (tester) async {
      final navigator = await _pumpShell(tester);
      procedure = _FakeRoomProcedure()..navigator = navigator;
      coordinator = RoomNavigationCoordinator(
          openRoom: procedure.open,
          navigatorOf: () => navigator,
          conversationKeyOf: (_) => 'dm:peer');
      await openRoom(tester, '!old:test');
      final original = coordinator.activeRoute('!old:test');
      if (afterRegister) {
        procedure.leakAndThrowFor = '!canonical:test';
      } else {
        procedure.failBeforeRegisterFor = '!canonical:test';
      }
      await expectLater(
          coordinator.open(request('!canonical:test')), throwsStateError);
      await tester.pumpAndSettle();
      expect(coordinator.activeRoute('!old:test'), same(original));
      expect(coordinator.isOpening('!old:test'), isFalse);
      await coordinator.open(const RoomOpenRequest(
          roomId: '!old:test',
          roomName: 'friend',
          anchorEventId: 'original-anchor',
          anchorRoomId: '!old:test'));
      await tester.pumpAndSettle();
      expect(procedure.leases, 2,
          reason:
              'failed replacement does not orphan the original active page');
      expect(procedure.reopened.single.anchorEventId, 'original-anchor');
      expect(find.text('room:!old:test'), findsOneWidget);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);
      expect(coordinator.activeRoomIds, isEmpty);
    });
  }

  testWidgets('Test 4: A → B 正常打开不同房间', (tester) async {
    await setUpCoordinator(tester);
    await openRoom(tester, '!a:test');
    await openRoom(tester, '!b:test');

    expect(procedure.opened, ['!a:test', '!b:test']);
    expect(procedure.leases, 2);
    expect(find.text('room:!b:test'), findsOneWidget);
    expect(coordinator.activeRoomIds, containsAll(['!a:test', '!b:test']));
  });

  testWidgets('Test 5: A → B → 再次打开 A 时 popUntil(A)，不产生第三层', (tester) async {
    await setUpCoordinator(tester);
    await openRoom(tester, '!a:test');
    await openRoom(tester, '!b:test');

    unawaited(coordinator.open(request('!a:test')));
    await tester.pumpAndSettle();

    expect(procedure.opened, ['!a:test', '!b:test'], reason: '不得再 push A');
    expect(procedure.leases, 2);
    expect(find.text('room:!b:test'), findsNothing);
    expect(find.text('room:!a:test'), findsOneWidget);
    expect(coordinator.activeRoomIds, ['!a:test'], reason: 'B 退出后释放登记');
  });

  testWidgets('Test 6: 页面退出后 registry 清理，随后可重新打开', (tester) async {
    await setUpCoordinator(tester);
    final opening = coordinator.open(request('!a:test'));
    await tester.pumpAndSettle();

    procedure.navigator!.pop();
    await tester.pumpAndSettle();
    await opening; // 页面关闭后 opening future 才完成

    expect(procedure.closed, ['!a:test']);
    expect(coordinator.activeRoute('!a:test'), isNull);
    expect(coordinator.isOpening('!a:test'), isFalse);

    await openRoom(tester, '!a:test');
    expect(procedure.leases, 2);
    expect(find.text('room:!a:test'), findsOneWidget);
  });

  testWidgets('Test 7: 打开流程抛异常时清理登记与 opening，不留下假 active', (tester) async {
    await setUpCoordinator(tester);
    procedure.leakAndThrowFor = '!a:test';
    await expectLater(coordinator.open(request('!a:test')), throwsStateError);
    await tester.pumpAndSettle();

    expect(coordinator.activeRoute('!a:test'), isNull);
    expect(coordinator.activeRoomIds, isEmpty);
    expect(coordinator.isOpening('!a:test'), isFalse);

    procedure.leakAndThrowFor = null;
    await openRoom(tester, '!a:test');
    expect(find.text('room:!a:test'), findsOneWidget, reason: '清理后可正常重开');
  });

  testWidgets('Test 8: dispose/clear 不把旧账号的房间登记泄漏给下一个账号', (tester) async {
    await setUpCoordinator(tester);
    await openRoom(tester, '!a:test');

    coordinator.clear();
    expect(coordinator.activeRoomIds, isEmpty);
    expect(coordinator.openingCount, 0);

    await openRoom(tester, '!b:test');
    expect(procedure.opened.last, '!b:test');

    coordinator.dispose();
    expect(coordinator.activeRoomIds, isEmpty);
    expect(coordinator.openingCount, 0);
    final leasesAfterDispose = procedure.leases;
    unawaited(coordinator.open(request('!c:test')));
    await tester.pumpAndSettle();
    expect(procedure.leases, leasesAfterDispose, reason: 'dispose 后不再打开任何房间');
  });

  testWidgets('Test 9: 房间 A 的租约取消不阻塞打开房间 B', (tester) async {
    await setUpCoordinator(tester);
    await openRoom(tester, '!a:test');

    // 关闭 A：取消租约被挂住（模拟真机 6 秒 drain）。
    procedure.holdCancel = Completer<void>();
    procedure.navigator!.pop();
    await tester.pumpAndSettle();
    expect(coordinator.activeRoute('!a:test'), isNull);

    await openRoom(tester, '!b:test');
    expect(find.text('room:!b:test'), findsOneWidget,
        reason: '另一个房间必须立即可打开，不被 A 的取消阻塞');
    expect(procedure.leases, 2);

    procedure.holdCancel!.complete();
    procedure.holdCancel = null;
    await tester.pumpAndSettle();
  });

  testWidgets('Test 10: 取消租约期间重新打开同一房间会新开页面（不是静默无操作）', (tester) async {
    await setUpCoordinator(tester);
    await openRoom(tester, '!a:test');

    procedure.holdCancel = Completer<void>();
    procedure.navigator!.pop();
    await tester.pumpAndSettle();
    expect(coordinator.activeRoute('!a:test'), isNull);

    await openRoom(tester, '!a:test');
    expect(procedure.leases, 2, reason: '旧租约仍在取消，但必须能重新打开');
    expect(find.text('room:!a:test'), findsOneWidget);

    procedure.holdCancel!.complete();
    procedure.holdCancel = null;
    await tester.pumpAndSettle();
  });

  testWidgets('onRoomReady/onRoomClosed 与 push 顺序一致', (tester) async {
    await setUpCoordinator(tester);
    final events = <String>[];
    final opening = coordinator.open(RoomOpenRequest(
      roomId: '!a:test',
      roomName: 'room !a',
      onRoomReady: () => events.add('ready'),
      onRoomClosed: () => events.add('closed'),
    ));
    await tester.pumpAndSettle();
    expect(events, ['ready']);
    expect(procedure.navigator!.canPop(), isTrue);

    procedure.navigator!.pop();
    await tester.pumpAndSettle();
    await opening;
    expect(events, ['ready', 'closed']);
  });
  testWidgets(
      'different physical rooms reuse one peer route and deliver a new source anchor',
      (tester) async {
    final navigator = await _pumpShell(tester);
    var pushes = 0;
    RoomOpenRequest? reopened;
    final coordinator = RoomNavigationCoordinator(
        conversationKeyOf: (_) => 'dm:peer',
        navigatorOf: () => navigator,
        openRoom: (request, handle) async {
          pushes++;
          final route = CupertinoPageRoute<void>(
              builder: (_) => const Text('logical conversation'));
          handle.register(route, onReopen: (value) => reopened = value);
          try {
            await navigator.push(route);
          } finally {
            handle.release(route);
          }
        });
    unawaited(coordinator.open(request('!primary:test')));
    await tester.pumpAndSettle();
    await coordinator.open(const RoomOpenRequest(
        roomId: '!primary:test',
        roomName: 'same friend',
        anchorEventId: r'$historical',
        anchorRoomId: '!old:test'));
    await tester.pumpAndSettle();
    expect(pushes, 1);
    expect(reopened?.anchorRoomId, '!old:test');
    expect(reopened?.anchorEventId, r'$historical');
    navigator.pop();
    await tester.pumpAndSettle();
    expect(coordinator.activeRoomIds, isEmpty);
  });
}
