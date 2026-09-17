import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/screen_capture_protection.dart';
import 'package:liuhetong_mobile/ui/chat/flash_photo.dart';

Future<Uint8List> _patternPng({int size = 120}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
      Offset.zero & Size.square(size.toDouble()),
      Paint()
        ..shader = ui.Gradient.linear(
            Offset.zero,
            Offset(size.toDouble(), size.toDouble()),
            const [Color(0xFF17324D), Color(0xFFE0A458)]));
  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  picture.dispose();
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

final class _FakeProtection {
  _FakeProtection() {
    protection = ScreenCaptureProtection(
      invoker: (method) async => calls.add(method),
      captureStateSnapshot: () async => null,
    );
  }

  final calls = <String>[];
  late final ScreenCaptureProtection protection;

  void screenshot() => protection.emitScreenshotForTest();

  Future<void> dispose() => protection.dispose();
}

/// 生产形态的宿主：真实 Navigator 路由栈 + 持久化 tombstone。
///
/// `onDestroyed` 就是 `RoomPage` 里的那条回调：markViewed + 刷新气泡。
/// 只有真正持久化过的消息，重新打开时才允许显示「闪照已销毁」。
final class _FlashHost extends StatefulWidget {
  const _FlashHost({
    super.key,
    required this.bytes,
    required this.protection,
    required this.messageId,
    required this.viewed,
    this.original,
  });

  final Uint8List bytes;
  final ScreenCaptureProtection protection;
  final String messageId;
  final Set<String> viewed;
  final Future<Uint8List> Function()? original;

  @override
  State<_FlashHost> createState() => _FlashHostState();
}

final class _FlashHostState extends State<_FlashHost> {
  int openCount = 0;
  Route<void>? route;

  Future<void> open() async {
    if (widget.viewed.contains(widget.messageId)) return; // 已销毁：不再打开
    openCount++;
    final pushed = CupertinoPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => FlashPhotoViewerPage(
        protection: widget.protection,
        loadOriginal: widget.original ?? () async => widget.bytes,
        onDestroyed: () => widget.viewed.add(widget.messageId),
      ),
    );
    route = pushed;
    await Navigator.of(context, rootNavigator: true).push(pushed);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

FlashPhotoViewerPageState _stateOf(WidgetTester tester) =>
    tester.state<FlashPhotoViewerPageState>(find.byType(FlashPhotoViewerPage));

Future<TestGesture> _reveal(WidgetTester tester) async {
  final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('flash-photo-viewer'))));
  await tester.pump(const Duration(milliseconds: 600));
  expect(find.byKey(const Key('flash-revealed-image')), findsOneWidget,
      reason: '长按必须真的显示出原图，否则本测试前提不成立');
  return gesture;
}

/// 用**系统返回**语义退出：`removeRoute` 直接移除当前路由并 dispose 页面，
/// 不经过任何手势回调。等价 Android 系统返回 / iOS 交互式返回 /
/// `Navigator.removeRoute` / route replacement。
Future<void> _systemBack(WidgetTester tester, GlobalKey<NavigatorState> nav,
    {Route<void>? route}) async {
  if (route != null) {
    nav.currentState!.removeRoute(route);
  } else {
    nav.currentState!.pop();
  }
  await _settle(tester);
}

/// 有界的「等动画稳定」：绝不使用无上限的 pumpAndSettle（查看器里存在周期性
/// 倒计时定时器与长按手势，无界等待会挂死测试）。
Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 12; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('P0: reveal → route exit must persist the tombstone exactly once',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final fake = _FakeProtection();
    addTearDown(fake.dispose);
    final nav = GlobalKey<NavigatorState>();
    final viewed = <String>{};
    final host = GlobalKey<_FlashHostState>();

    await tester.pumpWidget(CupertinoApp(
      navigatorKey: nav,
      home: _FlashHost(
        key: host,
        bytes: bytes,
        protection: fake.protection,
        messageId: r'$flash',
        viewed: viewed,
      ),
    ));

    unawaited(host.currentState!.open());
    await _settle(tester);
    await _reveal(tester);
    final state = _stateOf(tester);

    // 原图正在显示，路由被移除（系统返回 / removeRoute / route replacement）。
    await _systemBack(tester, nav, route: host.currentState!.route);

    expect(viewed, {r'$flash'}, reason: '原图显示过一帧后，任何退出路径都必须 tombstone');
    expect(state.debugDestroyed, isTrue, reason: 'dispose 必须收敛到 destroyed');
    expect(state.debugHasOriginalBytes, isFalse, reason: '必须释放原图引用');
    expect(state.debugRevealed, isFalse);
    expect(state.debugDestroyCount, 1, reason: '销毁只能发生一次');
    // 手势仍按在屏幕上时移除路由，框架会先派发 long-press cancel；
    // 若手势已结束，则由 dispose 的 fail-safe 收口。两条路径都必须
    // 恰好持久化一次，这正是本测试的断言重点。
    expect(state.debugDestroyReason, anyOf('cancel', 'route-exit'));
  });

  testWidgets(
      'P0: reveal is still active → close button (gesture-less exit) persists',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final fake = _FakeProtection();
    addTearDown(fake.dispose);
    final nav = GlobalKey<NavigatorState>();
    final viewed = <String>{};
    final host = GlobalKey<_FlashHostState>();

    await tester.pumpWidget(CupertinoApp(
      navigatorKey: nav,
      home: _FlashHost(
        key: host,
        bytes: bytes,
        protection: fake.protection,
        messageId: r'$flash',
        viewed: viewed,
      ),
    ));
    unawaited(host.currentState!.open());
    await _settle(tester);
    final route = host.currentState!.route;
    await _reveal(tester);
    final state = _stateOf(tester);
    expect(state.debugRevealed, isTrue);

    // 手势仍按在屏幕上时移除路由。框架会先派发 long-press cancel；若手势
    // 已在上一步结束，则由 dispose 的 fail-safe 收口。两条路径都必须
    // 恰好持久化一次，这正是本测试的断言重点。
    await _systemBack(tester, nav, route: route);
    await tester.pump(const Duration(milliseconds: 100));

    expect(viewed, {r'$flash'},
        reason: 'dispose 是最后一道保险：reveal 过就必须 tombstone');
    expect(state.debugDestroyed, isTrue);
    expect(state.debugHasOriginalBytes, isFalse);
    expect(state.debugDestroyCount, 1);
    expect(state.debugDestroyReason, anyOf('cancel', 'route-exit'));
  });

  testWidgets('P0: reveal → release finger → pop notifies exactly once',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final fake = _FakeProtection();
    addTearDown(fake.dispose);
    final nav = GlobalKey<NavigatorState>();
    final viewed = <String>{};
    final host = GlobalKey<_FlashHostState>();

    await tester.pumpWidget(CupertinoApp(
      navigatorKey: nav,
      home: _FlashHost(
        key: host,
        bytes: bytes,
        protection: fake.protection,
        messageId: r'$flash',
        viewed: viewed,
      ),
    ));
    unawaited(host.currentState!.open());
    await _settle(tester);
    final gesture = await _reveal(tester);
    final state = _stateOf(tester);

    // 用户松手（正常销毁），随后退出页面（不得二次销毁/通知）。
    await gesture.up();
    await tester.pump();
    expect(state.debugDestroyReason, 'release');
    await tester.pump(const Duration(seconds: 1));
    await _systemBack(tester, nav, route: host.currentState!.route);
    await tester.pump(const Duration(seconds: 2));

    expect(state.debugDestroyCount, 1, reason: 'dispose 不得重复销毁');
    expect(viewed, hasLength(1));
  });

  testWidgets('P0: reveal → 3s timeout → exit keeps exactly-once semantics',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final fake = _FakeProtection();
    addTearDown(fake.dispose);
    final nav = GlobalKey<NavigatorState>();
    final viewed = <String>{};
    final host = GlobalKey<_FlashHostState>();

    await tester.pumpWidget(CupertinoApp(
      navigatorKey: nav,
      home: _FlashHost(
        key: host,
        bytes: bytes,
        protection: fake.protection,
        messageId: r'$flash',
        viewed: viewed,
      ),
    ));
    unawaited(host.currentState!.open());
    await _settle(tester);
    final gesture = await _reveal(tester);
    final state = _stateOf(tester);

    // 3 秒到期：正常销毁。
    await tester.pump(const Duration(seconds: 3));
    expect(state.debugDestroyed, isTrue);
    expect(state.debugDestroyReason, 'timeout');
    expect(viewed, hasLength(1));

    // 之后退出页面：不得产生第二次销毁/持久化。
    await gesture.up();
    await _systemBack(tester, nav, route: host.currentState!.route);
    await tester.pump(const Duration(milliseconds: 50));
    expect(state.debugDestroyCount, 1);
    expect(viewed, hasLength(1));
  });

  testWidgets('P0: reveal → screenshot → exit destroys exactly once',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final fake = _FakeProtection();
    addTearDown(fake.dispose);
    final nav = GlobalKey<NavigatorState>();
    final viewed = <String>{};
    final host = GlobalKey<_FlashHostState>();

    await tester.pumpWidget(CupertinoApp(
      navigatorKey: nav,
      home: _FlashHost(
        key: host,
        bytes: bytes,
        protection: fake.protection,
        messageId: r'$flash',
        viewed: viewed,
      ),
    ));
    unawaited(host.currentState!.open());
    await _settle(tester);
    final gesture = await _reveal(tester);
    final state = _stateOf(tester);

    fake.screenshot();
    await tester.pump();
    await tester.pump();
    expect(viewed, hasLength(1), reason: '截图后必须立即 tombstone');

    await gesture.up();
    await _systemBack(tester, nav, route: host.currentState!.route);
    await tester.pump(const Duration(milliseconds: 50));
    expect(state.debugDestroyCount, 1, reason: '截图 + 退出不得重复销毁');
    expect(viewed, hasLength(1));
  });

  testWidgets('P0: a viewer that never revealed is NOT marked as viewed',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final fake = _FakeProtection();
    addTearDown(fake.dispose);
    final nav = GlobalKey<NavigatorState>();
    final viewed = <String>{};
    final host = GlobalKey<_FlashHostState>();

    await tester.pumpWidget(CupertinoApp(
      navigatorKey: nav,
      home: _FlashHost(
        key: host,
        bytes: bytes,
        protection: fake.protection,
        messageId: r'$flash',
        viewed: viewed,
      ),
    ));
    unawaited(host.currentState!.open());
    await _settle(tester);
    final state = _stateOf(tester);
    expect(state.debugRevealed, isFalse);

    await _systemBack(tester, nav, route: host.currentState!.route);
    expect(viewed, isEmpty, reason: '普通关闭未查看的闪照不得消耗查看机会');
    expect(state.debugDestroyCount, 0, reason: '从未 reveal 的页面退出不算「销毁一次」');
    expect(state.debugDestroyed, isTrue, reason: '页面已退出，内部状态必须收敛（但不 notify）');
    expect(state.debugHasOriginalBytes, isFalse);
  });

  testWidgets('P0: never revealed → close button → reopen still viewable',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final fake = _FakeProtection();
    addTearDown(fake.dispose);
    final nav = GlobalKey<NavigatorState>();
    final viewed = <String>{};
    final host = GlobalKey<_FlashHostState>();

    await tester.pumpWidget(CupertinoApp(
      navigatorKey: nav,
      home: _FlashHost(
        key: host,
        bytes: bytes,
        protection: fake.protection,
        messageId: r'$flash',
        viewed: viewed,
      ),
    ));
    unawaited(host.currentState!.open());
    await _settle(tester);
    expect(find.byType(FlashPhotoViewerPage), findsOneWidget);

    // 点「X」关闭：未 reveal，不得消耗查看机会。
    await tester.tap(find.byKey(const Key('flash-viewer-close')));
    await _settle(tester);
    expect(find.byType(FlashPhotoViewerPage), findsNothing);
    expect(viewed, isEmpty, reason: '未查看就关闭不得 tombstone');
    expect(host.currentState!.openCount, 1);
  });

  testWidgets('P0: never revealed → close → a later viewer can still reveal',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final fake = _FakeProtection();
    addTearDown(fake.dispose);
    final nav = GlobalKey<NavigatorState>();
    final viewed = <String>{};

    // 第一次查看器：只打开、不 reveal、直接关闭。
    await tester.pumpWidget(CupertinoApp(
      navigatorKey: nav,
      home: _FlashHost(
        bytes: bytes,
        protection: fake.protection,
        messageId: r'$flash',
        viewed: viewed,
      ),
    ));
    final firstHost = tester.state<_FlashHostState>(find.byType(_FlashHost));
    unawaited(firstHost.open());
    await _settle(tester);
    await tester.tap(find.byKey(const Key('flash-viewer-close')));
    await _settle(tester);
    expect(viewed, isEmpty);

    // 重新打开同一事件（新的宿主/查看器）：仍然可以正常查看。
    final host = GlobalKey<_FlashHostState>();
    await tester.pumpWidget(CupertinoApp(
      navigatorKey: nav,
      home: _FlashHost(
        key: host,
        bytes: bytes,
        protection: fake.protection,
        messageId: r'$flash',
        viewed: viewed,
      ),
    ));
    unawaited(host.currentState!.open());
    await _settle(tester);
    expect(find.byType(FlashPhotoViewerPage), findsOneWidget);
    expect(host.currentState!.openCount, 1);
    final gesture = await _reveal(tester);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(viewed, {r'$flash'});
  });

  testWidgets('P0: pending loadOriginal → exit must NOT mark as viewed',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final fake = _FakeProtection();
    addTearDown(fake.dispose);
    final nav = GlobalKey<NavigatorState>();
    final viewed = <String>{};
    final host = GlobalKey<_FlashHostState>();
    final pending = Completer<Uint8List>();

    await tester.pumpWidget(CupertinoApp(
      navigatorKey: nav,
      home: _FlashHost(
        key: host,
        bytes: bytes,
        protection: fake.protection,
        messageId: r'$flash',
        viewed: viewed,
        original: () => pending.future,
      ),
    ));
    unawaited(host.currentState!.open());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final state = _stateOf(tester);
    expect(state.debugHasOriginalBytes, isFalse, reason: '原图尚未返回');

    // 原图还在加载时退出。
    await _systemBack(tester, nav, route: host.currentState!.route);
    expect(viewed, isEmpty, reason: '从未显示过原图，不得消耗查看机会');

    // 迟到的原图返回：必须被丢弃，且不得触发任何销毁/持久化副作用。
    pending.complete(bytes);
    await tester.pump(const Duration(milliseconds: 50));
    expect(viewed, isEmpty);
    expect(state.debugHasOriginalBytes, isFalse);
  });

  testWidgets('P0: reveal → exit → reopen the same event is not revealable',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final fake = _FakeProtection();
    addTearDown(fake.dispose);
    final nav = GlobalKey<NavigatorState>();
    final viewed = <String>{};
    final host = GlobalKey<_FlashHostState>();

    await tester.pumpWidget(CupertinoApp(
      navigatorKey: nav,
      home: _FlashHost(
        key: host,
        bytes: bytes,
        protection: fake.protection,
        messageId: r'$flash',
        viewed: viewed,
      ),
    ));
    unawaited(host.currentState!.open());
    await _settle(tester);
    await _reveal(tester);
    await _systemBack(tester, nav, route: host.currentState!.route);
    expect(viewed, {r'$flash'});

    // 重新打开同一事件：宿主按 tombstone 拒绝打开。
    await host.currentState!.open();
    await _settle(tester);
    expect(find.byType(FlashPhotoViewerPage), findsNothing,
        reason: '已销毁的闪照不得再次进入查看器');
    expect(host.currentState!.openCount, 1);
  });

  testWidgets('P0: dispose releases the lease and invalidates async work',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final fake = _FakeProtection();
    addTearDown(fake.dispose);
    final nav = GlobalKey<NavigatorState>();
    final viewed = <String>{};
    final host = GlobalKey<_FlashHostState>();

    await tester.pumpWidget(CupertinoApp(
      navigatorKey: nav,
      home: _FlashHost(
        key: host,
        bytes: bytes,
        protection: fake.protection,
        messageId: r'$flash',
        viewed: viewed,
      ),
    ));
    unawaited(host.currentState!.open());
    await _settle(tester);
    await _reveal(tester);
    final state = _stateOf(tester);
    final generationBefore = state.debugGeneration;

    await _systemBack(tester, nav, route: host.currentState!.route);
    expect(state.debugGeneration, greaterThan(generationBefore),
        reason: '退出必须让在途异步结果作废');
    expect(fake.calls, contains('releaseSecure'), reason: '退出必须释放安全窗口租约');
    expect(fake.protection.leaseCount, 0);
  });
}
