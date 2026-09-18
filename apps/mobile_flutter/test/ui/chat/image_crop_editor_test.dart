import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/image_crop_geometry.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_image_editor.dart';

const _sourceSide = 100.0;

Future<Uint8List> _solidPng(int size, Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Offset.zero & Size.square(size.toDouble()), Paint()..color = color);
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

Future<Uint8List> _whitePng({int size = 100}) =>
    _solidPng(size, const Color(0xFFFFFFFF));

Future<({int width, int height})> _dimensions(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final size = (width: frame.image.width, height: frame.image.height);
  frame.image.dispose();
  codec.dispose();
  return size;
}

Finder get _editorCanvas => find.byWidgetPredicate(
    (widget) => widget is CustomPaint && widget.painter is ImageEditorPainter);

ImageEditorPainter _painter(WidgetTester tester) =>
    tester.widget<CustomPaint>(_editorCanvas).painter! as ImageEditorPainter;

Rect _viewBoxGlobal(WidgetTester tester) =>
    _painter(tester).viewBox.shift(tester.getRect(_editorCanvas).topLeft);

/// 裁剪框（全局坐标）。
Rect _frameGlobal(WidgetTester tester) =>
    _painter(tester).selection!.shift(tester.getRect(_editorCanvas).topLeft);

Future<void> _pumpEditor(
  WidgetTester tester,
  Uint8List bytes, {
  Future<bool> Function(Future<Uint8List> Function())? onForward,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(CupertinoApp(
      home: WeChatImageEditorPage(bytes: bytes, onForward: onForward)));
  await _waitForEditor(tester);
}

Future<void> _waitForEditor(WidgetTester tester) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    if (find.byKey(const Key('image-editor-crop')).evaluate().isNotEmpty) {
      return;
    }
  }
  expect(find.byKey(const Key('image-editor-crop')), findsOneWidget);
}

Future<void> _openCrop(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('image-editor-crop')));
  await tester.pump();
  expect(_painter(tester).selection, isNotNull, reason: '裁剪模式必须绘制裁剪框');
}

Future<void> _drag(WidgetTester tester, Offset from, Offset to) async {
  final gesture = await tester.startGesture(from);
  // 分步移动：单步大位移可能被识别成 fling / 跳过命中测试。
  for (var step = 1; step <= 4; step++) {
    await gesture.moveTo(Offset.lerp(from, to, step / 4)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 100));
}

/// 单次渲染读取多个采样点（避免重复渲染大图）。
Future<List<Color>> _samples(WidgetTester tester, List<Offset> points) async {
  final rect = tester.getRect(_editorCanvas);
  final painter = _painter(tester);
  final size = rect.size;
  final result = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    painter.paint(canvas, size);
    final picture = recorder.endRecording();
    final image =
        await picture.toImage(size.width.round(), size.height.round());
    picture.dispose();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final pixels = data!.buffer.asUint8List();
      return [
        for (final point in points)
          () {
            final local = point - rect.topLeft;
            final x = local.dx.round().clamp(0, image.width - 1);
            final y = local.dy.round().clamp(0, image.height - 1);
            final offset = (y * image.width + x) * 4;
            return Color.fromARGB(pixels[offset + 3], pixels[offset],
                pixels[offset + 1], pixels[offset + 2]);
          }()
      ];
    } finally {
      image.dispose();
    }
  });
  return result!;
}

BoxDecoration? _decorationOf(WidgetTester tester, Key key) {
  for (final box in tester.widgetList<DecoratedBox>(find.descendant(
      of: find.byKey(key), matching: find.byType(DecoratedBox)))) {
    final decoration = box.decoration;
    if (decoration is BoxDecoration && decoration.borderRadius != null) {
      return decoration;
    }
  }
  return null;
}

void main() {
  testWidgets('Test1 打开裁剪：裁剪框默认覆盖整张图片（不是固定小框）',
      (tester) async {
    await _pumpEditor(tester, (await tester.runAsync(_whitePng))!);
    await _openCrop(tester);

    final painter = _painter(tester);
    final frame = painter.selection!;
    final box = painter.viewBox;

    expect(frame.left, closeTo(box.left, .01));
    expect(frame.top, closeTo(box.top, .01));
    expect(frame.width, closeTo(box.width, .01));
    expect(frame.height, closeTo(box.height, .01));
    expect(frame.width * frame.height,
        greaterThan(box.width * box.height * .95),
        reason: '默认裁剪框必须覆盖整张图片');
    expect(painter.viewScale, 1);
    expect(painter.viewOffset, Offset.zero);
  });

  testWidgets('裁剪框有半透明遮罩、明显边框与四角/四边控制点', (tester) async {
    await _pumpEditor(tester, (await tester.runAsync(_whitePng))!);
    await _openCrop(tester);
    final box = _viewBoxGlobal(tester);
    await _drag(tester, box.topLeft + const Offset(2, 2),
        box.topLeft + const Offset(82, 62));

    final shrunk = _frameGlobal(tester);
    expect(shrunk.width, lessThan(box.width), reason: '裁剪框必须能收进');
    final samples = await _samples(tester, [
      shrunk.center, // 框内：原图不被压暗
      Offset(shrunk.left - 25, shrunk.center.dy), // 框外：半透明遮罩
      Offset(shrunk.left, shrunk.center.dy), // 左边框：明显亮线
      Offset(shrunk.topLeft.dx + 8, shrunk.topLeft.dy - 1), // 左上角控制点
      Offset(shrunk.topLeft.dx + 60, shrunk.topLeft.dy - 1), // 边上无控制点
    ]);

    expect(samples[0].r, greaterThan(.9), reason: '框内保持原图亮度');
    expect(samples[1].r, lessThan(.7), reason: '框外必须有半透明遮罩');
    expect(samples[2].r, greaterThan(.85), reason: '裁剪框必须有明显边框');
    expect(samples[3].r, greaterThan(.95), reason: '四角必须有控制点');
    expect(samples[4].r, lessThan(samples[3].r - .1),
        reason: '控制点只在四角/四边中点，边上不会糊满整条边');
  });

  testWidgets('拖动中控制点高亮，松手后恢复', (tester) async {
    await _pumpEditor(tester, (await tester.runAsync(_whitePng))!);
    await _openCrop(tester);
    final box = _viewBoxGlobal(tester);
    final gesture = await tester.startGesture(box.topLeft + const Offset(2, 2));
    await gesture.moveTo(box.topLeft + const Offset(40, 30));
    await tester.pump(const Duration(milliseconds: 16));

    expect(_painter(tester).activeHandle, CropHandle.topLeft,
        reason: '拖动中控制点必须高亮');
    final active = await _samples(
        tester, [box.topLeft + const Offset(28, 30 - 1)]);
    expect(active.first.b, greaterThan(.3), reason: '高亮使用品牌色而非白色');

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_painter(tester).activeHandle, CropHandle.none,
        reason: '松手后取消高亮');
  });

  testWidgets('Test2 拖动四角：裁剪区域变化', (tester) async {
    await _pumpEditor(tester, (await tester.runAsync(_whitePng))!);
    await _openCrop(tester);
    final box = _viewBoxGlobal(tester);

    await _drag(tester, box.topLeft, box.topLeft + const Offset(60, 40));
    var frame = _frameGlobal(tester);
    expect(frame.left, closeTo(box.left + 60, 1.5));
    expect(frame.top, closeTo(box.top + 40, 1.5));
    expect(frame.right, closeTo(box.right, 1.5));
    expect(frame.bottom, closeTo(box.bottom, 1.5));

    await _drag(tester,
        box.bottomRight - const Offset(3, 3),
        box.bottomRight - const Offset(53, 33));
    frame = _frameGlobal(tester);
    expect(frame.right, closeTo(box.right - 50, 1.5));
    expect(frame.bottom, closeTo(box.bottom - 30, 1.5));
    expect(frame.left, closeTo(box.left + 60, 1.5),
        reason: '拖右下角不得影响左上角');
  });

  testWidgets('Test3 拖动四边：区域变化且另一轴不动', (tester) async {
    await _pumpEditor(tester, (await tester.runAsync(_whitePng))!);
    await _openCrop(tester);
    final box = _viewBoxGlobal(tester);

    await _drag(tester,
        Offset(box.center.dx, box.top), Offset(box.center.dx, box.top + 45));
    var frame = _frameGlobal(tester);
    expect(frame.top, closeTo(box.top + 45, 1.5));
    expect(frame.left, closeTo(box.left, .01));
    expect(frame.right, closeTo(box.right, .01));
    expect(frame.bottom, closeTo(box.bottom, .01));

    await _drag(tester, Offset(frame.left, frame.center.dy),
        Offset(frame.left + 55, frame.center.dy));
    frame = _frameGlobal(tester);
    expect(frame.left, closeTo(box.left + 55, 1.5));
    expect(frame.top, closeTo(box.top + 45, 1.5), reason: '拖左边不得改动上边');
  });

  testWidgets('Test4 点击还原：恢复原始图片状态 / 默认裁剪框 / 默认缩放与旋转',
      (tester) async {
    await _pumpEditor(tester, (await tester.runAsync(_whitePng))!);
    await _openCrop(tester);
    final box = _viewBoxGlobal(tester);

    await _drag(tester, box.topLeft, box.topLeft + const Offset(70, 50));
    await tester.tap(find.byKey(const Key('image-editor-crop-rotate')));
    await tester.pump();
    await _pinch(tester, scale: 2.2);
    expect(_painter(tester).viewScale, greaterThan(1));

    await tester.tap(find.byKey(const Key('image-editor-crop-reset')));
    await tester.pump();

    final painter = _painter(tester);
    final frame = painter.selection!;
    final restored = painter.viewBox;
    expect(painter.document.rotation, 0, reason: '默认旋转');
    expect(painter.document.crop,
        const Rect.fromLTWH(0, 0, _sourceSide, _sourceSide),
        reason: '原始图片状态');
    expect(painter.document.marks, isEmpty);
    expect(painter.viewScale, 1, reason: '默认缩放');
    expect(painter.viewOffset, Offset.zero);
    expect(frame.left, closeTo(restored.left, .01), reason: '默认裁剪框');
    expect(frame.width, closeTo(restored.width, .01));
  });

  testWidgets('Test5 点击应用裁剪：生成新图片且原图保持', (tester) async {
    final source = (await tester.runAsync(_whitePng))!;
    final original = Uint8List.fromList(source);
    final exports = <Uint8List>[];
    await _pumpEditor(tester, source, onForward: (export) async {
      exports.add(await export());
      return true;
    });
    await _openCrop(tester);
    final box = _viewBoxGlobal(tester);
    await _drag(tester, box.topLeft, box.topLeft + const Offset(70, 50));
    final frame = _frameGlobal(tester);
    final expectedWidth = (frame.width / box.width * _sourceSide).round();
    final expectedHeight = (frame.height / box.height * _sourceSide).round();

    await tester.tap(find.byKey(const Key('image-editor-apply-crop')));
    await tester.pump(const Duration(milliseconds: 300));

    final crop = _painter(tester).document.crop;
    expect(crop.width, lessThan(_sourceSide));
    expect(crop.height, lessThan(_sourceSide));
    expect(crop.left, greaterThan(0));
    expect(crop.top, greaterThan(0));
    expect(_painter(tester).selection!.width,
        closeTo(_painter(tester).viewBox.width, .01),
        reason: '应用后裁剪框回到「覆盖整张图片」');

    // 导出 → 新的媒体对象（尺寸 = 裁剪区域），原字节保持不变。
    await tester.tap(find.byKey(const Key('image-editor-done')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('转发'));
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 400));

    expect(exports, isNotEmpty);
    final exported = (await tester.runAsync(() => _dimensions(exports.last)))!;
    expect(exported.width, closeTo(expectedWidth, 2));
    expect(exported.height, closeTo(expectedHeight, 2));
    expect(source, original, reason: '编辑绝不覆盖原图字节');
    final sourceSize = (await tester.runAsync(() => _dimensions(source)))!;
    expect(sourceSize.width, _sourceSide.round());
    expect(sourceSize.height, _sourceSide.round());
  });

  testWidgets('Test6 取消编辑：原图不变化，也不产生任何输出', (tester) async {
    final source = (await tester.runAsync(_whitePng))!;
    final original = Uint8List.fromList(source);
    var forwarded = 0;
    var sent = 0;
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(CupertinoApp(
        home: Builder(
            builder: (context) => CupertinoPageScaffold(
                child: Center(
                    child: CupertinoButton(
                        key: const Key('host-open'),
                        onPressed: () => Navigator.of(context).push(
                            CupertinoPageRoute(
                                builder: (_) => WeChatImageEditorPage(
                                    bytes: source,
                                    onForward: (export) async {
                                      forwarded++;
                                      return true;
                                    },
                                    onSend: (bytes) async {
                                      sent++;
                                      return true;
                                    }))),
                        child: const Text('打开编辑器')))))));
    await tester.tap(find.byKey(const Key('host-open')));
    await tester.pump();
    // 路由过渡必须走完，否则导航栏按钮不可点。
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await _waitForEditor(tester);
    await _openCrop(tester);
    final box = _viewBoxGlobal(tester);
    await _drag(tester, box.topLeft, box.topLeft + const Offset(60, 40));

    await tester.tap(find.byKey(const Key('image-editor-cancel')));
    // 编辑器加载态有无限动画，不能用 pumpAndSettle。
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }

    expect(find.byType(WeChatImageEditorPage), findsNothing);
    expect(find.byKey(const Key('host-open')), findsOneWidget);
    expect(forwarded, 0);
    expect(sent, 0);
    expect(source, original, reason: '取消不得修改原图字节');
  });

  testWidgets('固定比例：切换 1:1 后裁剪框保持宽高比', (tester) async {
    await _pumpEditor(tester, (await tester.runAsync(_whitePng))!);
    await _openCrop(tester);
    await tester.tap(find.byKey(const Key('image-editor-crop-aspect-1-1')));
    await tester.pump();

    final frame = _frameGlobal(tester);
    expect(frame.width / frame.height, closeTo(1, .02));

    await tester.tap(find.byKey(const Key('image-editor-crop-aspect-16-9')));
    await tester.pump();
    final wide = _frameGlobal(tester);
    expect(wide.width / wide.height, closeTo(16 / 9, .02));

    await tester.tap(find.byKey(const Key('image-editor-crop-aspect-free')));
    await tester.pump();
    await _drag(tester, wide.topLeft, wide.topLeft + const Offset(40, 5));
    final free = _frameGlobal(tester);
    expect(free.width / free.height, isNot(closeTo(16 / 9, .05)),
        reason: '自由裁剪不再强制比例');
  });

  testWidgets('旋转：文档旋转 90° 且还原可回到 0', (tester) async {
    await _pumpEditor(tester, (await tester.runAsync(_whitePng))!);
    await _openCrop(tester);
    await tester.tap(find.byKey(const Key('image-editor-crop-rotate')));
    await tester.pump();
    expect(_painter(tester).document.rotation, 1);
    await tester.tap(find.byKey(const Key('image-editor-crop-rotate')));
    await tester.pump();
    expect(_painter(tester).document.rotation, 2);
    await tester.tap(find.byKey(const Key('image-editor-crop-reset')));
    await tester.pump();
    expect(_painter(tester).document.rotation, 0);
  });

  testWidgets('缩放与移动：双指放大后可拖动画面', (tester) async {
    await _pumpEditor(tester, (await tester.runAsync(_whitePng))!);
    await _openCrop(tester);
    final center = _viewBoxGlobal(tester).center;

    await _pinch(tester, scale: 3, center: center);
    expect(_painter(tester).viewScale, greaterThan(1.4),
        reason: '双指捏合必须放大画面');

    await _drag(tester, center, center + const Offset(25, 18));
    expect(_painter(tester).viewOffset.dx.abs() + _painter(tester).viewOffset.dy.abs(),
        greaterThan(4),
        reason: '放大后可以拖动画面改变裁剪内容');
  });

  testWidgets('还原 / 应用裁剪：高度、圆角一致，应用裁剪有填充背景',
      (tester) async {
    await _pumpEditor(tester, (await tester.runAsync(_whitePng))!);
    await _openCrop(tester);

    const resetKey = Key('image-editor-crop-reset');
    const applyKey = Key('image-editor-apply-crop');
    expect(find.byKey(resetKey), findsOneWidget);
    expect(find.byKey(applyKey), findsOneWidget);

    final resetSize = tester.getSize(find.byKey(resetKey));
    final applySize = tester.getSize(find.byKey(applyKey));
    expect(resetSize.height, ImageEditorActionButton.height);
    expect(resetSize, applySize, reason: '两个按钮高度/宽度一致');

    final reset = _decorationOf(tester, resetKey)!;
    final apply = _decorationOf(tester, applyKey)!;
    expect(apply.borderRadius, reset.borderRadius, reason: '圆角一致');
    expect(apply.color, isNotNull, reason: '应用裁剪必须有背景色');
    expect(reset.color, isNotNull);
    expect(apply.color, isNot(reset.color), reason: '应用裁剪是主色高亮');

    // 间距一致：两按钮之间只有固定的 12pt 间隔。
    final resetRect = tester.getRect(find.byKey(resetKey));
    final applyRect = tester.getRect(find.byKey(applyKey));
    expect(applyRect.left - resetRect.right, closeTo(12, .5));
    expect(resetRect.left, closeTo(390 - applyRect.right, .5),
        reason: '左右留白一致');
  });
}

/// 双指捏合（[scale] > 1 放大）。
Future<void> _pinch(WidgetTester tester,
    {required double scale, Offset? center}) async {
  final focal = center ?? _viewBoxGlobal(tester).center;
  const reach = 30.0;
  final first = await tester.startGesture(focal - const Offset(reach, 0));
  final second = await tester.startGesture(focal + const Offset(reach, 0));
  await tester.pump(const Duration(milliseconds: 16));
  final target = reach * scale;
  for (var step = 1; step <= 4; step++) {
    final offset = Offset(reach + (target - reach) * step / 4, 0);
    await first.moveTo(focal - offset);
    await second.moveTo(focal + offset);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await first.up();
  await second.up();
  await tester.pump(const Duration(milliseconds: 100));
}
