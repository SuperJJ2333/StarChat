import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
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

void main() {
  testWidgets('viewer: hold reveals original with countdown, timeout destroys',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    var destroyed = 0;
    await tester.pumpWidget(CupertinoApp(
      home: FlashPhotoViewerPage(
        loadOriginal: () async => bytes,
        onDestroyed: () => destroyed++,
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 初始：马赛克 + 闪电 + 长按提示；无倒计时环。
    expect(find.byKey(const Key('flash-mosaic-image')), findsOneWidget);
    expect(find.byKey(const Key('flash-bolt-badge')), findsOneWidget);
    expect(find.text('长按屏幕可查看 5 秒'), findsOneWidget);
    expect(find.byKey(const Key('flash-countdown-ring')), findsNothing);

    // 长按：原图 + 倒计时环出现。
    final gesture = await tester.startGesture(tester.getCenter(
        find.byKey(const Key('flash-photo-viewer'))));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const Key('flash-revealed-image')), findsOneWidget);
    expect(find.byKey(const Key('flash-countdown-ring')), findsOneWidget);

    // 倒计时走完 5 秒：恢复马赛克并销毁。
    await tester.pump(const Duration(seconds: 5));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('flash-revealed-image')), findsNothing);
    expect(find.byKey(const Key('flash-mosaic-image')), findsOneWidget);
    expect(find.text('闪照已销毁'), findsOneWidget);
    expect(destroyed, 1);
  });

  testWidgets('viewer: releasing early also destroys and fires callback',
      (tester) async {
    final bytes = (await tester.runAsync(_patternPng))!;
    var destroyed = 0;
    await tester.pumpWidget(CupertinoApp(
      home: FlashPhotoViewerPage(
        loadOriginal: () async => bytes,
        onDestroyed: () => destroyed++,
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('flash-photo-viewer'))));
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.byKey(const Key('flash-revealed-image')), findsOneWidget);

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('flash-revealed-image')), findsNothing);
    expect(find.text('闪照已销毁'), findsOneWidget);
    expect(destroyed, 1);
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
}
