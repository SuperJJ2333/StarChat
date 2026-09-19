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

ImageEditorPainter _painter(WidgetTester tester) =>
    tester.widget<CustomPaint>(_editorCanvas).painter! as ImageEditorPainter;

/// 画布现在是整个编辑区域，图片按 contain 居中适配——因此图片坐标必须
/// 经 [ImageEditorPainter.viewBox] 映射，不能按画布百分比推算。
Rect _viewBoxGlobal(WidgetTester tester) {
  final canvas = tester.getRect(_editorCanvas);
  return _painter(tester).viewBox.shift(canvas.topLeft);
}

/// 图片内的百分比坐标 → 全局坐标。
Offset _imagePoint(WidgetTester tester, double x, double y) {
  final box = _viewBoxGlobal(tester);
  return Offset(
      box.left + box.width * x / 100, box.top + box.height * y / 100);
}

/// 当前裁剪框（全局坐标）。
Rect _cropFrameGlobal(WidgetTester tester) {
  final canvas = tester.getRect(_editorCanvas);
  return _painter(tester).selection!.shift(canvas.topLeft);
}

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

  testWidgets('BUG-27 转发被接受后显示瞬态「已转发」，不再滞留「正在发送」',
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
    // 导出 PNG 是真实异步，需要 runAsync 等任务接受完成后提示才出现。
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(exports, isNotEmpty);
    expect(find.text('正在发送'), findsNothing,
        reason: '不得再显示永远不会更新的「正在发送」');
    expect(find.text('已转发'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('已转发'), findsNothing, reason: '瞬态提示自动消失');
  });

  testWidgets('BUG-25 收藏成功提示 3 秒后自动消失', (tester) async {
    final source = (await tester.runAsync(_patternPng))!;
    await tester.pumpWidget(CupertinoApp(
      home: WeChatImageEditorPage(
        bytes: source,
        onFavorite: (_) async {},
      ),
    ));
    await _waitForEditor(tester);
    await tester.tap(find.byKey(const Key('image-editor-done')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('收藏'));
    // 导出 PNG 是真实异步，需要 runAsync 等它完成。
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('已收藏'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('已收藏'), findsNothing,
        reason: '成功提示必须自动消失，不得常驻画布');
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

    Offset point(int x, int y) => _imagePoint(tester, x.toDouble(), y.toDouble());

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

    Offset originalPoint(int x, int y) =>
        _imagePoint(tester, x.toDouble(), y.toDouble());

    // 新裁剪交互：裁剪框默认覆盖整张图片，拖动**左上角控制点**收进。
    await tester.tap(find.byKey(const Key('image-editor-crop')));
    await tester.pump();
    final frame = _cropFrameGlobal(tester);
    await _draw(tester, frame.topLeft, originalPoint(20, 20));
    await tester.tap(find.byKey(const Key('image-editor-apply-crop')));
    await tester.pump(const Duration(milliseconds: 300));
    final crop = _painter(tester).document.crop;
    expect(crop.contains(const Offset(25, 50)), isTrue);
    expect(crop.width, lessThan(100), reason: '裁剪必须真的收进，而不是整图');
    await _exportThroughForward(tester, exports);
    final croppedX = (25 - crop.left).round();
    final croppedY = (50 - crop.top).round();
    final expected =
        await tester.runAsync(() => _pixel(exports.last, croppedX, croppedY));

    Offset croppedPoint(int x, int y) {
      final box = _viewBoxGlobal(tester);
      return Offset(box.left + box.width * (x - crop.left) / crop.width,
          box.top + box.height * (y - crop.top) / crop.height);
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
