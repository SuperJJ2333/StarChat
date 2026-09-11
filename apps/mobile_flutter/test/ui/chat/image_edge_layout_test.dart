import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/contain_image_bubble.dart';
import 'package:liuhetong_mobile/ui/chat/encrypted_media_view.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_message_bubble.dart';

Future<Uint8List> picture(int w, int h) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(CupertinoColors.systemBlue, BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(w, h);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}

Rect paintedImage(WidgetTester tester) {
  final finder = find.byType(RawImage).first;
  final render = tester.renderObject<RenderImage>(finder);
  final pixels =
      Size(render.image!.width.toDouble(), render.image!.height.toDouble());
  final fitted = applyBoxFit(render.fit!, pixels, render.size);
  return render.alignment
      .resolve(TextDirection.ltr)
      .inscribe(fitted.destination, tester.getRect(finder));
}

Future<void> settleDecodedImage(
  WidgetTester tester,
  Uint8List bytes, {
  required Finder contextFinder,
  int maxEdge = 720,
}) async {
  // MediaVisibility publishes after layout, and Image's stream resolves after
  // that publication. Precache the same bounded provider rather than racing a
  // wall-clock delay before reading RenderImage.image.
  await tester.pump();
  await tester.runAsync(() => precacheImage(
      boundedChatImageProvider(bytes, maxEdge: maxEdge),
      tester.element(contextFinder)));
  await tester.pump();
  await tester.pumpAndSettle();
}

void main() {
  for (final direction in MessageDirection.values) {
    for (final size in [
      const Size(160, 90),
      const Size(160, 120),
      const Size(90, 160)
    ]) {
      testWidgets(
          '$direction $size unknown metadata keeps painted edge next to avatar',
          (tester) async {
        final bytes = (await tester
            .runAsync(() => picture(size.width.toInt(), size.height.toInt())))!;
        await tester.pumpWidget(CupertinoApp(
            home: Center(
                child: SizedBox(
          width: 400,
          child: WeChatMessageBubble(
            direction: direction,
            avatar: const ColoredBox(color: CupertinoColors.systemGreen),
            decorateContent: false,
            content: LayoutBuilder(
                builder: (context, constraints) => ContainImageBubble(
                      initialBytes: bytes,
                      load: () async => bytes,
                      availableWidth: constraints.maxWidth,
                      availableHeight: 400,
                    )),
          ),
        ))));
        await settleDecodedImage(tester, bytes,
            contextFinder: find.byType(ContainImageBubble));
        final image = paintedImage(tester);
        final avatar =
            tester.getRect(find.byKey(const Key('message-avatar-slot')));
        final gap = direction == MessageDirection.outgoing
            ? avatar.left - image.right
            : image.left - avatar.right;
        expect(gap, closeTo(8, .01));
      });
    }
  }

  testWidgets(
      'small landscape preview expands to viewport width and double tap resets',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = (await tester.runAsync(() => picture(160, 90)))!;
    await tester
        .pumpWidget(CupertinoApp(home: ImageViewerPage(previewBytes: bytes)));
    await settleDecodedImage(tester, bytes,
        contextFinder: find.byType(ImageViewerPage), maxEdge: 2048);
    expect(paintedImage(tester).width, closeTo(400, .01));
    final viewer =
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    final point = tester.getCenter(find.byType(InteractiveViewer));
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(point);
    await tester.pumpAndSettle();
    expect(viewer.transformationController!.value.getMaxScaleOnAxis(),
        greaterThan(1));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(point);
    await tester.pumpAndSettle();
    expect(viewer.transformationController!.value.getMaxScaleOnAxis(), 1);
    tester.view.physicalSize = const Size(800, 400);
    await tester.pumpAndSettle();
    final viewport = tester.getSize(find.byType(InteractiveViewer));
    final expected = applyBoxFit(BoxFit.contain, const Size(160, 90), viewport);
    expect(paintedImage(tester).size, expected.destination);
    expect(tester.takeException(), isNull);
  });
}
