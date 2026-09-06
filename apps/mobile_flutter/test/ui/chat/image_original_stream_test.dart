import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/contain_image_bubble.dart';

void main() {
  testWidgets('static preview is replaced by original animated content',
      (tester) async {
    const header = [
      71,
      73,
      70,
      56,
      57,
      97,
      1,
      0,
      1,
      0,
      128,
      0,
      0,
      0,
      0,
      0,
      255,
      255,
      255
    ];
    const frame = [
      33,
      249,
      4,
      0,
      10,
      0,
      0,
      0,
      44,
      0,
      0,
      0,
      0,
      1,
      0,
      1,
      0,
      0,
      2,
      2,
      68,
      1,
      0
    ];
    final preview = Uint8List.fromList([...header, ...frame, 59]);
    final original = Uint8List.fromList([...header, ...frame, ...frame, 59]);
    final source = Completer<Uint8List>();
    var loads = 0;
    await tester.pumpWidget(CupertinoApp(
        home: Center(
            child: ContainImageBubble(
      initialBytes: preview,
      refreshFromSource: true,
      load: () {
        loads++;
        return source.future;
      },
    ))));
    expect(loads, 1);
    source.complete(original);
    await tester.pump();
    await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(original);
      expect(codec.frameCount, 2);
      codec.dispose();
    });
    await tester.pump(const Duration(milliseconds: 200));
    final rendered = tester.widget<Image>(find.byType(Image).first);
    final resized = rendered.image as ResizeImage;
    expect((resized.imageProvider as MemoryImage).bytes, original);
    expect(resized.policy, ResizeImagePolicy.fit);
    expect(resized.width, 720);
    expect(resized.height, 720);
    final imageKey = await resized.obtainKey(const ImageConfiguration());
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
      if (!PaintingBinding.instance.imageCache.statusForKey(imageKey).pending) {
        break;
      }
    }
    expect(PaintingBinding.instance.imageCache.statusForKey(imageKey).pending,
        isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(PaintingBinding.instance.imageCache.statusForKey(imageKey).live,
        isFalse,
        reason: 'disposing the bubble releases its image listeners');
  });
}
