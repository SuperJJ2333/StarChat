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
        ..shader = ui.Gradient.linear(Offset.zero,
            Offset(size.toDouble(), size.toDouble()), const [
          Color(0xFF17324D),
          Color(0xFFE0A458)
        ]));
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
final class _FakeProtection {
  final calls = <String>[];
  late final ScreenCaptureProtection protection = ScreenCaptureProtection(
    invoker: (method) async => calls.add(method),
  );

  void capture(bool active) =>
      protection.emitCaptureStateForTest(active);
  void screenshot() => protection.emitScreenshotForTest();

  Future<void> dispose() => protection.dispose();
}

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
    expect(
        flashViewerHintText(destroyed: false, captureActive: false),
        '长按屏幕可查看 3 秒');
    expect(flashViewerHintText(destroyed: true, captureActive: false),
        '闪照已销毁');
    expect(flashViewerHintText(destroyed: false, captureActive: true),
        '正在录屏或共享屏幕，无法查看闪照');
  });

  testWidgets('viewer: hold reveals original with 3s countdown, timeout destroys',
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

  testWidgets('secure lease: acquire on open, release on dispose, idempotent',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    final fake = _FakeProtection();
    addTearDown(fake.dispose);
    await _pumpViewer(tester, _viewer(bytes: bytes, protection: fake.protection));
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
    await _pumpViewer(tester, _viewer(bytes: bytes, protection: fake.protection));

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
    await _pumpViewer(tester, _viewer(bytes: bytes, protection: fake.protection));
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

    tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
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

  test('viewed store persists per account and caps growth', () async {
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

    // 超出上限淘汰最旧。
    for (var i = 3; i <= 600; i++) {
      store.markViewed('e$i');
    }
    expect(store.isViewed('e1'), isFalse);
    expect(store.isViewed('e600'), isTrue);
  });

  test('protection: platform-unavailable degrade is silent and safe', () async {
    final protection = ScreenCaptureProtection(
      invoker: (method) async => throw StateError('missing plugin'),
      captureEvents: const Stream<Object?>.empty(),
    );
    final lease = await protection.acquire();
    expect(protection.leaseCount, 1);
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
    final subscription = protection.screenshots.listen((_) => screenshots.add(1));
    protection.emitCaptureStateForTest(true);
    expect(protection.captureActive.value, isTrue);
    protection.emitScreenshotForTest();
    await Future<void>.delayed(Duration.zero);
    expect(screenshots, hasLength(1));
    protection.emitCaptureStateForTest(false);
    expect(protection.captureActive.value, isFalse);
    await subscription.cancel();
    await protection.dispose();
  });
}
