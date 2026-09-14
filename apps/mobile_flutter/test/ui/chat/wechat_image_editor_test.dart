import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_image_editor.dart';

Future<Uint8List> _patternPng({int size = 100}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
      Offset.zero & Size.square(size.toDouble()),
      Paint()
        ..shader = ui.Gradient.linear(
            Offset.zero,
            Offset(size.toDouble(), size.toDouble()),
            const [Color(0xFF17324D), Color(0xFFE0A458)]));
  final line = Paint()..color = const Color(0xFFFAF3DD);
  for (var x = 0; x < size; x += 10) {
    canvas.drawRect(Rect.fromLTWH(x.toDouble(), 0, 4, size.toDouble()), line);
  }
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

Future<Color> _pixel(Uint8List bytes, int x, int y) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final image = (await codec.getNextFrame()).image;
  codec.dispose();
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final offset = (y * image.width + x) * 4;
    final pixels = data!.buffer.asUint8List();
    return Color.fromARGB(pixels[offset + 3], pixels[offset],
        pixels[offset + 1], pixels[offset + 2]);
  } finally {
    image.dispose();
  }
}

Finder get _editorCanvas => find.byWidgetPredicate(
    (widget) => widget is CustomPaint && widget.painter is ImageEditorPainter);

Future<void> _draw(WidgetTester tester, Offset start, Offset end) async {
  final gesture = await tester.startGesture(start);
  await gesture.moveTo(end);
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _waitForEditor(WidgetTester tester) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    if (find.byKey(const Key('image-editor-brush')).evaluate().isNotEmpty) {
      return;
    }
  }
  expect(find.byKey(const Key('image-editor-brush')), findsOneWidget);
}

Future<void> _exportThroughForward(
  WidgetTester tester,
  List<Uint8List> exports,
) async {
  await tester.tap(find.byKey(const Key('image-editor-done')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  final forward = find.text('转发');
  await tester.ensureVisible(forward);
  await tester.tap(forward);
  await tester.pump();
  await tester
      .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  await tester.pump(const Duration(milliseconds: 400));
  expect(exports, isNotEmpty);
}

void main() {
  for (final width in [320.0, 390.0]) {
    testWidgets('emoji chooser is centered with fixed touch targets at $width',
        (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final bytes = (await tester.runAsync(_patternPng))!;

      await tester.pumpWidget(CupertinoApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: WeChatImageEditorPage(bytes: bytes),
      ));
      await _waitForEditor(tester);
      await tester.tap(find.byKey(const Key('image-editor-emoji')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final grid = find.byKey(const Key('image-editor-emoji-grid'));
      final firstEmoji = find.byKey(const Key('image-editor-emoji-cell-😀'));
      expect(grid, findsOneWidget);
      expect(firstEmoji, findsOneWidget);
      expect(tester.getSize(firstEmoji), const Size(48, 48));
      expect(tester.getRect(grid).center.dx, closeTo(width / 2, 0.5));
      expect(tester.takeException(), isNull,
          reason: 'large text must not overflow or displace emoji cells');

      await tester.ensureVisible(firstEmoji);
      await tester.tap(firstEmoji);
      await tester.pumpAndSettle();
      expect(grid, findsNothing, reason: 'an emoji cell selects the overlay');
      await tester.tap(find.byKey(const Key('image-editor-eraser')));
      await tester.pump();
      expect(find.byType(CupertinoSlider), findsOneWidget);
      expect(tester.takeException(), isNull,
          reason:
              'large text must keep eraser guidance and width control usable');
    });
  }

  testWidgets('forward callback runs before any export work (deferred PNG)',
      (tester) async {
    final source = (await tester.runAsync(_patternPng))!;
    final exports = <Uint8List>[];
    var forwardedBeforeExport = false;
    var exportRequested = false;
    await tester.pumpWidget(CupertinoApp(
      home: WeChatImageEditorPage(
        bytes: source,
        onForward: (export) async {
          // 选择器打开（回调触发）时必须尚未发生导出。
          forwardedBeforeExport = !exportRequested;
          exportRequested = true;
          exports.add(await export());
          return true;
        },
      ),
    ));
    await _waitForEditor(tester);
    await _exportThroughForward(tester, exports);

    expect(forwardedBeforeExport, isTrue,
        reason: '导出必须发生在转发确认之后，选择器不能先等 PNG 编码');
  });

  testWidgets('successful editor forward reports queued sending state',
      (tester) async {
    final source = (await tester.runAsync(_patternPng))!;
    final exports = <Uint8List>[];
    await tester.pumpWidget(CupertinoApp(
      home: WeChatImageEditorPage(
        bytes: source,
        onForward: (export) async {
          exports.add(await export());
          return true;
        },
      ),
    ));
    await _waitForEditor(tester);
    await _exportThroughForward(tester, exports);

    expect(find.text('正在发送'), findsOneWidget);
    expect(find.text('已转发'), findsNothing);
  });
  testWidgets(
      'eraser removes only its touched edit layer and undo redo exports it',
      (tester) async {
    final source = (await tester.runAsync(_patternPng))!;
    final exports = <Uint8List>[];
    await tester.pumpWidget(CupertinoApp(
      home: WeChatImageEditorPage(
        bytes: source,
        onForward: (export) async {
          exports.add(await export());
          return true;
        },
      ),
    ));
    await _waitForEditor(tester);

    await _exportThroughForward(tester, exports);
    final erasedSource =
        await tester.runAsync(() => _pixel(exports.last, 25, 50));
    final retainedSource =
        await tester.runAsync(() => _pixel(exports.last, 72, 50));
    final mosaicSource =
        await tester.runAsync(() => _pixel(exports.last, 52, 18));
    expect(find.byKey(const Key('image-editor-mosaic')), findsOneWidget);
    expect(find.byKey(const Key('image-editor-eraser')), findsOneWidget,
        reason: 'eraser is an independent tool, not a mosaic alias');
    expect(find.byIcon(CupertinoIcons.delete_left), findsNothing,
        reason: 'the eraser uses a drawing icon rather than a backspace glyph');

    Offset point(int x, int y) {
      final canvas = tester.getRect(_editorCanvas);
      return Offset(canvas.left + canvas.width * x / 100,
          canvas.top + canvas.height * y / 100);
    }

    await _draw(tester, point(25, 50), point(30, 50));
    await _draw(tester, point(72, 50), point(77, 50));
    await tester.tap(find.byKey(const Key('image-editor-mosaic')));
    await tester.pump(const Duration(milliseconds: 300));
    await _draw(tester, point(52, 18), point(57, 18));
    await _exportThroughForward(tester, exports);
    expect(await tester.runAsync(() => _pixel(exports.last, 25, 50)),
        isNot(erasedSource),
        reason: 'the first brush stroke changes exported pixels');
    expect(await tester.runAsync(() => _pixel(exports.last, 72, 50)),
        isNot(retainedSource),
        reason: 'a separate brush stroke is retained');
    expect(await tester.runAsync(() => _pixel(exports.last, 52, 18)),
        isNot(mosaicSource),
        reason: 'mosaic is a distinct pixelation effect on textured source');

    await tester.tap(find.byKey(const Key('image-editor-eraser')));
    await tester.pump(const Duration(milliseconds: 400));
    await _draw(tester, point(25, 50), point(30, 50));
    await _exportThroughForward(tester, exports);
    expect(
        await tester.runAsync(() => _pixel(exports.last, 25, 50)), erasedSource,
        reason:
            'erasing restores only the original source pixels below its stroke');
    expect(await tester.runAsync(() => _pixel(exports.last, 72, 50)),
        isNot(retainedSource),
        reason: 'an untouched edit layer remains after local erasing');
    expect(await tester.runAsync(() => _pixel(exports.last, 52, 18)),
        isNot(mosaicSource),
        reason: 'eraser and mosaic remain independent tools');
    expect((await tester.runAsync(() => _pixel(exports.last, 25, 50)))!.a,
        erasedSource!.a,
        reason: 'eraser preserves original opaque alpha');

    await tester.tap(find.byKey(const Key('image-editor-undo')));
    await tester.pump(const Duration(milliseconds: 400));
    await _exportThroughForward(tester, exports);
    expect(await tester.runAsync(() => _pixel(exports.last, 25, 50)),
        isNot(erasedSource),
        reason: 'undo restores the removed editing layer');

    await tester.tap(find.byKey(const Key('image-editor-redo')));
    await tester.pump(const Duration(milliseconds: 400));
    await _exportThroughForward(tester, exports);
    expect(
        await tester.runAsync(() => _pixel(exports.last, 25, 50)), erasedSource,
        reason: 'redo reapplies the removal without changing source pixels');
  });

  testWidgets('cropping keeps the source position revealed by an eraser',
      (tester) async {
    final source = (await tester.runAsync(_patternPng))!;
    final exports = <Uint8List>[];
    await tester.pumpWidget(CupertinoApp(
        home: WeChatImageEditorPage(
            bytes: source,
            onForward: (export) async {
              exports.add(await export());
              return true;
            })));
    await _waitForEditor(tester);

    Offset originalPoint(int x, int y) {
      final canvas = tester.getRect(_editorCanvas);
      return Offset(canvas.left + canvas.width * x / 100,
          canvas.top + canvas.height * y / 100);
    }

    await tester.tap(find.byKey(const Key('image-editor-crop')));
    await tester.pump();
    await _draw(tester, originalPoint(20, 20), originalPoint(80, 80));
    await tester.tap(find.byKey(const Key('image-editor-apply-crop')));
    await tester.pump(const Duration(milliseconds: 300));
    final crop = (tester.widget<CustomPaint>(_editorCanvas).painter
            as ImageEditorPainter)
        .document
        .crop;
    expect(crop.contains(const Offset(25, 50)), isTrue);
    await _exportThroughForward(tester, exports);
    final croppedX = (25 - crop.left).round();
    final croppedY = (50 - crop.top).round();
    final expected =
        await tester.runAsync(() => _pixel(exports.last, croppedX, croppedY));

    Offset croppedPoint(int x, int y) {
      final canvas = tester.getRect(_editorCanvas);
      return Offset(canvas.left + canvas.width * (x - crop.left) / crop.width,
          canvas.top + canvas.height * (y - crop.top) / crop.height);
    }

    await tester.tap(find.byKey(const Key('image-editor-brush')));
    await tester.pump();
    await _draw(tester, croppedPoint(24, 50), croppedPoint(30, 50));
    await tester.tap(find.byKey(const Key('image-editor-eraser')));
    await tester.pump();
    await _draw(tester, croppedPoint(24, 50), croppedPoint(30, 50));
    await _exportThroughForward(tester, exports);
    expect(
        await tester.runAsync(() => _pixel(exports.last, croppedX, croppedY)),
        expected,
        reason:
            'the cropped export reveals the original pixel at source (25,50)');
  });
}
