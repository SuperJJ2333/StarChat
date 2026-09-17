import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/screen_capture_protection.dart';
import 'package:liuhetong_mobile/ui/chat/flash_photo.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// 记录平台调用的假实现（对应 Android chatflow/screen_security 契约）。
///
/// [snapshot] 对应 `getCurrentCaptureState`：不传表示「平台不提供捕获上报能力」
/// （等价 Android，安全窗口确认后按 inactive 处理）。
final class _FakeProtection {
  _FakeProtection({ScreenCaptureSnapshotInvoker? snapshot}) {
    protection = ScreenCaptureProtection(
      invoker: (method) async => calls.add(method),
      captureStateSnapshot: snapshot,
    );
  }

  final calls = <String>[];
  late final ScreenCaptureProtection protection;

  void capture(bool active) => protection.emitCaptureStateForTest(active);
  void screenshot() => protection.emitScreenshotForTest();

  Future<void> dispose() => protection.dispose();
}

FlashPhotoViewerPageState _stateOf(WidgetTester tester) =>
    tester.state<FlashPhotoViewerPageState>(find.byType(FlashPhotoViewerPage));

Widget _viewer({
  required Uint8List bytes,
  required ScreenCaptureProtection protection,
  VoidCallback? onDestroyed,
}) =>
    CupertinoApp(
      home: FlashPhotoViewerPage(
        protection: protection,
        loadOriginal: () async => bytes,
        onDestroyed: onDestroyed,
      ),
    );

Future<void> _pumpViewer(WidgetTester tester, Widget widget) async {
  await tester.pumpWidget(widget);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

Future<TestGesture> _longPress(WidgetTester tester) async {
  final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('flash-photo-viewer'))));
  await tester.pump(const Duration(milliseconds: 600));
  return gesture;
}

void main() {
  test('view duration is the product-mandated 3 seconds', () {
    expect(FlashPhotoViewerPage.viewDuration, const Duration(seconds: 3));
    expect(flashViewerHintText(destroyed: false, captureActive: false),
        '长按屏幕可查看 3 秒');
    expect(flashViewerHintText(destroyed: true, captureActive: false), '闪照已销毁');
    expect(flashViewerHintText(destroyed: false, captureActive: true),
        '正在录屏或共享屏幕，无法查看闪照');
  });

  testWidgets(
      'viewer: hold reveals original with 3s countdown, timeout destroys',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final fake = _FakeProtection();
    addTearDown(fake.dispose);
    var destroyed = 0;
    await _pumpViewer(
        tester,
        _viewer(
            bytes: bytes,
            protection: fake.protection,
            onDestroyed: () => destroyed++));

    // 初始：马赛克 + 闪电 + 长按提示；无倒计时环。
    expect(find.byKey(const Key('flash-mosaic-image')), findsOneWidget);
    expect(find.byKey(const Key('flash-bolt-badge')), findsOneWidget);
    expect(find.text('长按屏幕可查看 3 秒'), findsOneWidget);
    expect(find.byKey(const Key('flash-countdown-ring')), findsNothing);
    // 进入查看器即持有安全窗口租约（不等长按）。
    expect(fake.calls, ['acquireSecure']);

    final gesture = await _longPress(tester);
    expect(find.byKey(const Key('flash-revealed-image')), findsOneWidget);
    expect(find.byKey(const Key('flash-countdown-ring')), findsOneWidget);
    // reveal 期间有轻量动态水印。
    expect(find.byKey(const Key('flash-watermark')), findsOneWidget);

    // 倒计时走完 3 秒：原图消失、进度销毁、原图引用释放。
    await tester.pump(const Duration(seconds: 3));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('flash-revealed-image')), findsNothing);
    expect(find.byKey(const Key('flash-mosaic-image')), findsNothing);
    expect(find.byKey(const Key('flash-viewer-destroyed')), findsOneWidget);
    expect(find.text('闪照已销毁'), findsOneWidget);
    expect(destroyed, 1);
  });

  testWidgets('viewer: releasing early also destroys and fires callback',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final fake = _FakeProtection();
    addTearDown(fake.dispose);
    var destroyed = 0;
    await _pumpViewer(
        tester,
        _viewer(
            bytes: bytes,
            protection: fake.protection,
            onDestroyed: () => destroyed++));

    final gesture = await _longPress(tester);
    expect(find.byKey(const Key('flash-revealed-image')), findsOneWidget);

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('flash-revealed-image')), findsNothing);
    expect(find.text('闪照已销毁'), findsOneWidget);
    expect(destroyed, 1);

    // 销毁后不可重新长按查看。
    await _longPress(tester);
    expect(find.byKey(const Key('flash-revealed-image')), findsNothing);
    expect(destroyed, 1);
  });

  testWidgets('C2: normal 3s timeout destroy releases the original bytes',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final fake = _FakeProtection();
    addTearDown(fake.dispose);
    await _pumpViewer(
        tester, _viewer(bytes: bytes, protection: fake.protection));
    final state = _stateOf(tester);
    expect(state.debugHasOriginalBytes, isTrue, reason: '未销毁时持有原图字节');

    final gesture = await _longPress(tester);
    expect(state.debugRevealed, isTrue);
    expect(find.byKey(const Key('flash-revealed-image')), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));

    // C2 回归：旧实现的正常超时路径只清 _revealed/_destroyed，
    // 原图解码字节被继续引用在内存里。
    expect(state.debugHasOriginalBytes, isFalse,
        reason: '正常 3 秒销毁后不得再持有原图字节引用');
    expect(state.debugDestroyReason, 'timeout');
    expect(state.debugDestroyCount, 1);
    // 可观察的 widget 状态：原图与马赛克都不在了。
    expect(find.byKey(const Key('flash-revealed-image')), findsNothing);
    expect(find.byKey(const Key('flash-mosaic-image')), findsNothing);
    expect(find.byKey(const Key('flash-viewer-destroyed')), findsOneWidget);
  });

  testWidgets('C2: early finger-up destroy releases the original bytes',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final fake = _FakeProtection();
    addTearDown(fake.dispose);
    await _pumpViewer(
        tester, _viewer(bytes: bytes, protection: fake.protection));
    final state = _stateOf(tester);

    final gesture = await _longPress(tester);
    expect(state.debugRevealed, isTrue);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));

    expect(state.debugHasOriginalBytes, isFalse, reason: '提前松手销毁后不得再持有原图字节引用');
    expect(state.debugDestroyReason, 'release');
    expect(state.debugDestroyCount, 1);
    expect(find.byKey(const Key('flash-revealed-image')), findsNothing);
    expect(find.byKey(const Key('flash-mosaic-image')), findsNothing);
  });

  testWidgets('C2: capture-triggered destroy releases the original bytes',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final fake = _FakeProtection();
    addTearDown(fake.dispose);
    await _pumpViewer(
        tester, _viewer(bytes: bytes, protection: fake.protection));
    final state = _stateOf(tester);

    final gesture = await _longPress(tester);
    expect(state.debugRevealed, isTrue);
    fake.capture(true);
    await tester.pump();

    expect(state.debugHasOriginalBytes, isFalse);
    expect(state.debugDestroyReason, 'capture-active');
    expect(state.debugDestroyCount, 1);
    expect(find.byKey(const Key('flash-revealed-image')), findsNothing);
    expect(find.byKey(const Key('flash-mosaic-image')), findsNothing);
    await gesture.up();
    await tester.pump(const Duration(seconds: 4));
    expect(state.debugDestroyCount, 1, reason: 'onDestroyed 恰好一次');
  });

  testWidgets('C3: stale load completing after destroy never re-acquires bytes',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final fake = _FakeProtection();
    addTearDown(fake.dispose);
    final pending = Completer<Uint8List>();
    await tester.pumpWidget(CupertinoApp(
      home: FlashPhotoViewerPage(
        protection: fake.protection,
        loadOriginal: () => pending.future,
      ),
    ));
    await tester.pump();
    final state = _stateOf(tester);
    expect(state.debugHasOriginalBytes, isFalse);

    // 加载仍在途时被销毁（截图信号）。
    fake.screenshot();
    await tester.pump();
    await tester.pump();
    expect(state.debugDestroyed, isTrue);
    expect(state.debugDestroyReason, 'screenshot');
    final generationAtDestroy = state.debugGeneration;

    // 迟到的解密结果：必须被丢弃，绝不 setState / 显示原图。
    pending.complete(bytes);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(state.debugGeneration, generationAtDestroy);
    expect(state.debugHasOriginalBytes, isFalse, reason: '过期异步结果必须立即丢弃字节引用');
    expect(find.byKey(const Key('flash-revealed-image')), findsNothing);
    expect(find.byKey(const Key('flash-mosaic-image')), findsNothing);
    expect(find.byKey(const Key('flash-viewer-destroyed')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('C2: destroy is exactly-once for overlapping triggers',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final fake = _FakeProtection();
    addTearDown(fake.dispose);
    var destroyed = 0;
    await _pumpViewer(
        tester,
        _viewer(
            bytes: bytes,
            protection: fake.protection,
            onDestroyed: () => destroyed++));
    final state = _stateOf(tester);
    final gesture = await _longPress(tester);

    // 显式安全事件 + 截图 + 松手 + 倒计时交叉触发。
    state.reportSecurityEvent();
    state.reportSecurityEvent();
    fake.screenshot();
    await tester.pump();
    fake.capture(true);
    await gesture.up();
    await tester.pump(const Duration(seconds: 4));
    expect(destroyed, 1);
    expect(state.debugDestroyCount, 1);
    expect(state.debugDestroyReason, 'security-event');
    expect(state.debugHasOriginalBytes, isFalse);
  });

  testWidgets('E: capture state unknown fails closed (no reveal)',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    // 快照调用失败 → captureState 保持 unknown（绝不当作 inactive）。
    final fake = _FakeProtection(
        snapshot: () async => throw StateError('snapshot channel broken'));
    addTearDown(fake.dispose);
    await _pumpViewer(
        tester, _viewer(bytes: bytes, protection: fake.protection));
    expect(fake.protection.captureState.value, ScreenCaptureState.unknown);
    expect(fake.protection.canReveal, isFalse);
    expect(find.text('无法确认屏幕安全状态，暂不可查看'), findsOneWidget);

    await _longPress(tester);
    expect(find.byKey(const Key('flash-revealed-image')), findsNothing,
        reason: '捕获状态未知必须 fail closed');
    expect(find.byKey(const Key('flash-mosaic-image')), findsOneWidget);
  });

  testWidgets('E: confirmed inactive capture can reveal', (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final fake = _FakeProtection(snapshot: () async => false);
    addTearDown(fake.dispose);
    await _pumpViewer(
        tester, _viewer(bytes: bytes, protection: fake.protection));
    expect(fake.protection.captureState.value, ScreenCaptureState.inactive);
    expect(fake.protection.readiness.value, ScreenProtectionReadiness.ready);
    expect(fake.protection.canReveal, isTrue);
    expect(find.text('长按屏幕可查看 3 秒'), findsOneWidget);

    final gesture = await _longPress(tester);
    expect(find.byKey(const Key('flash-revealed-image')), findsOneWidget);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('E: snapshot reporting recording at open blocks reveal',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    // 设备在查看器打开之前就已在录屏：快照必须立刻拦住 reveal。
    final fake = _FakeProtection(snapshot: () async => true);
    addTearDown(fake.dispose);
    await _pumpViewer(
        tester, _viewer(bytes: bytes, protection: fake.protection));
    expect(fake.protection.captureState.value, ScreenCaptureState.active);
    expect(find.text('正在录屏或共享屏幕，无法查看闪照'), findsOneWidget);

    await _longPress(tester);
    expect(find.byKey(const Key('flash-revealed-image')), findsNothing);
  });

  testWidgets('E: protection not ready (initializing) cannot reveal',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final gate = Completer<void>();
    final protection = ScreenCaptureProtection(
      invoker: (_) => gate.future,
      captureStateSnapshot: () async => false,
    );
    addTearDown(protection.dispose);
    await _pumpViewer(tester, _viewer(bytes: bytes, protection: protection));
    expect(protection.readiness.value, ScreenProtectionReadiness.initializing);
    expect(find.text('正在启用闪照安全保护，请稍候'), findsOneWidget);

    final blocked = await _longPress(tester);
    expect(find.byKey(const Key('flash-revealed-image')), findsNothing,
        reason: '安全窗口未确认前不得 reveal');
    await blocked.up();
    await tester.pump();

    // 安全窗口确认后（同一查看器）可以正常查看。
    gate.complete();
    // 一次 pump 完成 async 链，再一次 pump 让 widget 用新状态重建。
    await tester.pump();
    await tester.pump();
    expect(protection.readiness.value, ScreenProtectionReadiness.ready);
    expect(find.text('长按屏幕可查看 3 秒'), findsOneWidget);
    final gesture = await _longPress(tester);
    expect(find.byKey(const Key('flash-revealed-image')), findsOneWidget);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('E: broken security channel fails closed with a clear message',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final protection = ScreenCaptureProtection(
      invoker: (method) async => throw StateError('MissingPlugin: $method'),
      captureStateSnapshot: () async => throw StateError('MissingPlugin'),
    );
    addTearDown(protection.dispose);
    await _pumpViewer(tester, _viewer(bytes: bytes, protection: protection));
    expect(protection.readiness.value, ScreenProtectionReadiness.failed);
    expect(find.text('当前设备无法启用闪照安全保护'), findsOneWidget);

    await _longPress(tester);
    expect(find.byKey(const Key('flash-revealed-image')), findsNothing,
        reason: '安全窗口不可用时绝不能静默显示原图');
    expect(find.byKey(const Key('flash-mosaic-image')), findsOneWidget);
  });

  testWidgets('secure lease: acquire on open, release on dispose, idempotent',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final fake = _FakeProtection();
    addTearDown(fake.dispose);
    await _pumpViewer(
        tester, _viewer(bytes: bytes, protection: fake.protection));
    expect(fake.calls, ['acquireSecure']);
    expect(fake.protection.leaseCount, 1);

    // 正常退出：释放最后一次租约 → 关闭 FLAG_SECURE。
    await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    await tester.pump();
    expect(fake.calls, ['acquireSecure', 'releaseSecure']);
    expect(fake.protection.leaseCount, 0);

    // 重复释放不会让计数变负。
    await fake.protection.releaseAll();
    expect(fake.calls, ['acquireSecure', 'releaseSecure']);
  });

  testWidgets('two viewers share one secure window until the last releases',
      (tester) async {
    final fake = _FakeProtection();
    addTearDown(fake.dispose);
    final first = await fake.protection.acquire();
    final second = await fake.protection.acquire();
    expect(fake.calls, ['acquireSecure'], reason: '第二个租约不再重复开启');
    expect(fake.protection.leaseCount, 2);

    await first.release();
    expect(fake.calls, ['acquireSecure'], reason: '仍有租约 → 保持开启');
    await first.release(); // 重复释放
    expect(fake.protection.leaseCount, 1);
    await second.release();
    expect(fake.calls, ['acquireSecure', 'releaseSecure']);
    expect(fake.protection.leaseCount, 0);
  });

  testWidgets('capture active before open: original never appears',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final fake = _FakeProtection()..capture(true);
    addTearDown(fake.dispose);
    await _pumpViewer(
        tester, _viewer(bytes: bytes, protection: fake.protection));

    expect(find.text('正在录屏或共享屏幕，无法查看闪照'), findsOneWidget);
    await _longPress(tester);
    expect(find.byKey(const Key('flash-revealed-image')), findsNothing,
        reason: '录屏中长按不得显示原图');
    expect(find.byKey(const Key('flash-mosaic-image')), findsOneWidget);
  });

  testWidgets('capture ending before viewing allows a normal reveal',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final fake = _FakeProtection()..capture(true);
    addTearDown(fake.dispose);
    await _pumpViewer(
        tester, _viewer(bytes: bytes, protection: fake.protection));
    final blocked = await _longPress(tester);
    expect(find.byKey(const Key('flash-revealed-image')), findsNothing);

    fake.capture(false);
    await tester.pump();
    expect(find.text('长按屏幕可查看 3 秒'), findsOneWidget);
    // 录屏中被屏蔽的那次长按本身不算“已查看”：松手后仍可正常查看。
    await blocked.up();
    await tester.pump();
    expect(find.byKey(const Key('flash-viewer-destroyed')), findsNothing);

    final gesture = await _longPress(tester);
    expect(find.byKey(const Key('flash-revealed-image')), findsOneWidget);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('capture starting during reveal destroys immediately',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final fake = _FakeProtection();
    addTearDown(fake.dispose);
    var destroyed = 0;
    await _pumpViewer(
        tester,
        _viewer(
            bytes: bytes,
            protection: fake.protection,
            onDestroyed: () => destroyed++));
    final gesture = await _longPress(tester);
    expect(find.byKey(const Key('flash-revealed-image')), findsOneWidget);

    fake.capture(true);
    await tester.pump();
    expect(find.byKey(const Key('flash-revealed-image')), findsNothing,
        reason: '检测到开始录屏 → 立即隐藏原图');
    expect(find.byKey(const Key('flash-viewer-destroyed')), findsOneWidget);
    expect(destroyed, 1);

    // 倒计时已被取消：继续 pump 不会产生第二次销毁回调。
    await gesture.up();
    await tester.pump(const Duration(seconds: 4));
    expect(destroyed, 1);
    // 销毁后即使录屏结束也不能恢复。
    fake.capture(false);
    await tester.pump();
    await _longPress(tester);
    expect(find.byKey(const Key('flash-revealed-image')), findsNothing);
  });

  testWidgets('screenshot event during reveal destroys (after-the-fact)',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final fake = _FakeProtection();
    addTearDown(fake.dispose);
    var destroyed = 0;
    await _pumpViewer(
        tester,
        _viewer(
            bytes: bytes,
            protection: fake.protection,
            onDestroyed: () => destroyed++));
    final gesture = await _longPress(tester);
    expect(find.byKey(const Key('flash-revealed-image')), findsOneWidget);

    // iOS：userDidTakeScreenshot 在系统截图完成之后到达——只能事后销毁。
    fake.screenshot();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('flash-revealed-image')), findsNothing);
    expect(find.byKey(const Key('flash-viewer-destroyed')), findsOneWidget);
    expect(destroyed, 1);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(destroyed, 1);
  });

  testWidgets('app resigning active during reveal hides original, no restore',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final fake = _FakeProtection();
    addTearDown(fake.dispose);
    var destroyed = 0;
    await _pumpViewer(
        tester,
        _viewer(
            bytes: bytes,
            protection: fake.protection,
            onDestroyed: () => destroyed++));
    final gesture = await _longPress(tester);
    expect(find.byKey(const Key('flash-revealed-image')), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.byKey(const Key('flash-revealed-image')), findsNothing);
    expect(destroyed, 1);

    // 回前台：不自动恢复原图，且重申安全窗口（Activity 重建兜底）。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('flash-revealed-image')), findsNothing);
    expect(find.byKey(const Key('flash-viewer-destroyed')), findsOneWidget);
    expect(fake.calls, contains('reassertSecure'));
  });

  testWidgets('bubble shows mosaic and bolt; destroyed caption when viewed',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    await tester.pumpWidget(CupertinoApp(
      home: Center(
        child: FlashPhotoBubble(
          loadOriginal: () async => bytes,
          viewed: false,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('flash-photo-bubble')), findsOneWidget);
    expect(find.byKey(const Key('flash-bolt-badge')), findsOneWidget);
    expect(find.text('闪照已销毁'), findsNothing);

    await tester.pumpWidget(CupertinoApp(
      home: Center(
        child: FlashPhotoBubble(
          loadOriginal: () async => bytes,
          viewed: true,
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('闪照已销毁'), findsOneWidget);
  });

  test('viewed store persists per account and never evicts tombstones',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = await FlashPhotoViewedStore.load('account-a');
    expect(store.isViewed('e1'), isFalse);
    store.markViewed('e1');
    store.markViewed('e2');
    expect(store.isViewed('e1'), isTrue);
    expect(store.isViewed('e2'), isTrue);

    // 另一账号隔离。
    final other = await FlashPhotoViewedStore.load('account-b');
    expect(other.isViewed('e1'), isFalse);
    other.markViewed('e1');
    expect(other.isViewed('e1'), isTrue);
    expect(store.isViewed('e1'), isTrue);

    // C1 回归：远超旧的 500 条上限后，最早的已销毁标记**绝不能**被淘汰
    // （否则已销毁的闪照会重新变成可查看 = 阅后即焚 fail-open）。
    for (var i = 3; i <= 600; i++) {
      store.markViewed('e$i');
    }
    expect(store.debugCount, 600, reason: '不得有任何容量淘汰');
    expect(store.isViewed('e1'), isTrue, reason: '第一张闪照必须保持已销毁');
    expect(store.isViewed('e2'), isTrue);
    expect(store.isViewed('e600'), isTrue);

    // 持久化仍然生效（重新加载后第一张依然是已销毁）。
    final reloaded = await FlashPhotoViewedStore.load('account-a');
    expect(reloaded.isViewed('e1'), isTrue);
    expect(reloaded.isViewed('e600'), isTrue);

    // 存储治理只跟随真实生命周期：消息永久删除 / 房间本地历史清空。
    store.dropForEventIds(['e1', 'e2']);
    expect(store.isViewed('e1'), isFalse);
    expect(store.isViewed('e600'), isTrue, reason: '不得连带清除其它事件');
    expect((await FlashPhotoViewedStore.load('account-a')).isViewed('e1'),
        isFalse);

    // 账号登出/重置：清空本账号全部标记（不影响其它账号）。
    await store.clear();
    expect(store.debugCount, 0);
    expect((await FlashPhotoViewedStore.load('account-a')).isViewed('e600'),
        isFalse);
    expect(
        (await FlashPhotoViewedStore.load('account-b')).isViewed('e1'), isTrue);
    await FlashPhotoViewedStore.clearAccount('account-b');
    expect((await FlashPhotoViewedStore.load('account-b')).isViewed('e1'),
        isFalse);
  });

  test('protection: platform-unavailable degrade is silent and safe', () async {
    final protection = ScreenCaptureProtection(
      invoker: (method) async => throw StateError('missing plugin'),
      captureEvents: const Stream<Object?>.empty(),
    );
    final lease = await protection.acquire();
    expect(protection.leaseCount, 1);
    // 通道失败不得抛异常，但必须 fail closed：readiness = failed。
    expect(protection.readiness.value, ScreenProtectionReadiness.failed);
    expect(protection.canReveal, isFalse);
    await lease.release();
    expect(protection.leaseCount, 0);
    await protection.dispose();
  });

  test('protection: platform events drive capture state and screenshot stream',
      () async {
    final protection = ScreenCaptureProtection(
      invoker: (method) async {},
      captureEvents: const Stream<Object?>.empty(),
    );
    final screenshots = <int>[];
    final subscription =
        protection.screenshots.listen((_) => screenshots.add(1));
    expect(protection.captureState.value, ScreenCaptureState.unknown,
        reason: '初始必须是 unknown（不得默认 inactive）');
    expect(protection.canReveal, isFalse);
    protection.emitCaptureStateForTest(true);
    expect(protection.captureActive.value, isTrue);
    expect(protection.captureState.value, ScreenCaptureState.active);
    protection.emitScreenshotForTest();
    await Future<void>.delayed(Duration.zero);
    expect(screenshots, hasLength(1));
    protection.emitCaptureStateForTest(false);
    expect(protection.captureActive.value, isFalse);
    expect(protection.captureState.value, ScreenCaptureState.inactive);
    await subscription.cancel();
    await protection.dispose();
  });
}
