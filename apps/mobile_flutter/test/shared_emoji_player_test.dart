import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:liuhetong_mobile/ui/chat/shared_emoji_player.dart';
import 'package:liuhetong_mobile/ui/chat/shared_emoji_image.dart';

class FakeCodec implements EmojiFrameCodec {
  FakeCodec(this.image);
  final ui.Image image;
  int calls = 0;
  bool disposed = false;
  @override
  int get frameCount => 3;
  @override
  Future<EmojiDecodedFrame> nextFrame() async {
    calls++;
    return EmojiDecodedFrame(image.clone(), const Duration(milliseconds: 20));
  }

  @override
  void dispose() => disposed = true;
}

Future<ui.Image> tinyImage([int size = 8]) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xff123456), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  picture.dispose();
  return image;
}

class CountLayouts extends SingleChildRenderObjectWidget {
  const CountLayouts({super.key, required this.onLayout, required super.child});
  final VoidCallback onLayout;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      LayoutCounter(onLayout);
}

class LayoutCounter extends RenderProxyBox {
  LayoutCounter(this.onLayout);
  final VoidCallback onLayout;
  @override
  void performLayout() {
    onLayout();
    super.performLayout();
  }
}

class PendingFrameCodec implements EmojiFrameCodec {
  final pending = Completer<EmojiDecodedFrame>();
  bool disposed = false;
  @override
  int get frameCount => 2;
  @override
  Future<EmojiDecodedFrame> nextFrame() => pending.future;
  @override
  void dispose() => disposed = true;
}

class HeldSecondCodec implements EmojiFrameCodec {
  HeldSecondCodec(this.image);
  final ui.Image image;
  final pending = Completer<EmojiDecodedFrame>();
  bool disposed = false;
  int calls = 0;
  @override
  int get frameCount => 3;
  @override
  Future<EmojiDecodedFrame> nextFrame() {
    calls++;
    return calls == 1
        ? Future.value(
            EmojiDecodedFrame(image.clone(), const Duration(milliseconds: 20)))
        : pending.future;
  }

  @override
  void dispose() {
    disposed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('warm subscription exposes the retained frame before visibility',
      (tester) async {
    final image = await tinyImage();
    final codecs = <FakeCodec>[];
    final pool = SharedEmojiPlayerPool(loader: (_, __) async {
      final codec = FakeCodec(image);
      codecs.add(codec);
      return codec;
    });
    final first = pool.subscribe(File('warm.webp'), 32)..setVisible(true);
    await tester.pump();
    final frame = first.frame;
    expect(frame, isNotNull);
    first.dispose();
    final reopened = pool.subscribe(File('warm.webp'), 32);
    expect(reopened.frame, same(frame));
    reopened.setVisible(true);
    await tester.pump();
    expect(codecs.length, 1);
    reopened.dispose();
    pool.dispose();
    image.dispose();
  });
  testWidgets('idle LRU count bytes codec budget and TTL stop hidden playback',
      (tester) async {
    final image = await tinyImage();
    final codecs = <FakeCodec>[];
    final pool = SharedEmojiPlayerPool(
        maxIdleEntries: 2,
        maxIdleFrameBytes: 512,
        maxIdleCodecs: 1,
        idleTtl: const Duration(milliseconds: 60),
        loader: (_, __) async {
          final c = FakeCodec(image);
          codecs.add(c);
          return c;
        });
    final handles = <EmojiPlayback>[];
    for (var i = 0; i < 3; i++) {
      final h = pool.subscribe(File('lru$i.webp'), 32)..setVisible(true);
      handles.add(h);
      await tester.pump();
      h.setVisible(false);
    }
    expect(pool.diagnostics['activeEntries'], 0);
    expect(pool.diagnostics['idleEntries'], 2);
    expect(pool.diagnostics['idleFrameBytes'], 512);
    expect(pool.diagnostics['idleCodecCount'], 1);
    expect(handles.first.frame, isNull);
    final calls = codecs.map((c) => c.calls).toList();
    await tester.pump(const Duration(milliseconds: 30));
    expect(codecs.map((c) => c.calls).toList(), calls);
    await tester.pump(const Duration(milliseconds: 40));
    expect(pool.diagnostics['totalFrameBytes'], 0);
    expect(pool.diagnostics['idleEntries'], 0);
    expect(codecs.every((c) => c.disposed), isTrue);
    for (final h in handles) {
      h.dispose();
    }
    pool.dispose();
    image.dispose();
  });
  testWidgets('idle pressure and background hard release borrowed first paints',
      (tester) async {
    final image = await tinyImage();
    final pool =
        SharedEmojiPlayerPool(loader: (_, __) async => FakeCodec(image));
    final a = pool.subscribe(File('pressure-warm.webp'), 32)..setVisible(true);
    await tester.pump();
    a.setVisible(false);
    final borrowed = pool.subscribe(File('pressure-warm.webp'), 32);
    expect(borrowed.frame, isNotNull);
    pool.didHaveMemoryPressure();
    expect(borrowed.frame, isNull);
    expect(pool.diagnostics['totalFrameBytes'], 0);
    await tester.pump(const Duration(milliseconds: 110));
    a.setVisible(true);
    await tester.pump();
    a.setVisible(false);
    pool.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(pool.diagnostics['idleEntries'], 0);
    expect(pool.diagnostics['totalFrameBytes'], 0);
    a.dispose();
    borrowed.dispose();
    pool.dispose();
    image.dispose();
  });
  testWidgets(
      'warm widget paints on its first build before visibility callback',
      (tester) async {
    final image = await tinyImage();
    final pool =
        SharedEmojiPlayerPool(loader: (_, __) async => FakeCodec(image));
    final h = pool.subscribe(File('widget-warm.webp'), 32)..setVisible(true);
    await tester.pump();
    h.dispose();
    await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(),
        child: Directionality(
            textDirection: TextDirection.ltr,
            child: SharedEmojiImage(
                file: File('widget-warm.webp'),
                size: 32,
                visible: false,
                fallback: const Text('OFFLINE'),
                pool: pool))));
    expect(find.text('OFFLINE'), findsNothing);
    final painted = tester.widget<CustomPaint>(find.byType(CustomPaint));
    final recorder = ui.PictureRecorder();
    painted.painter!.paint(ui.Canvas(recorder), const Size(32, 32));
    final picture = recorder.endRecording();
    final output = (await tester.runAsync(() => picture.toImage(32, 32)))!;
    final bytes = await tester.runAsync(() => output.toByteData());
    expect(bytes!.getUint32(0), isNot(0));
    output.dispose();
    picture.dispose();
    await tester.pumpWidget(const SizedBox());
    pool.dispose();
    image.dispose();
  });
  testWidgets(
      'async held frame exits idle without publishing and pressure frees it safely',
      (tester) async {
    final image = await tinyImage();
    final codec = HeldSecondCodec(image);
    final pool = SharedEmojiPlayerPool(loader: (_, __) async => codec);
    final h = pool.subscribe(File('held.webp'), 32)..setVisible(true);
    await tester.pump();
    final original = h.frame;
    await tester.pump(const Duration(milliseconds: 25));
    expect(codec.calls, 2);
    h.setVisible(false);
    final emitted = pool.diagnostics['framesEmitted'];
    expect(h.frame, same(original));
    pool.didHaveMemoryPressure();
    expect(h.frame, isNull);
    expect(codec.disposed, isFalse);
    codec.pending.complete(
        EmojiDecodedFrame(image.clone(), const Duration(milliseconds: 20)));
    await tester.pump();
    expect(codec.disposed, isTrue);
    expect(pool.diagnostics['framesEmitted'], emitted);
    expect(pool.diagnostics['totalFrameBytes'], 0);
    h.dispose();
    pool.dispose();
    image.dispose();
    await tester.pump(const Duration(milliseconds: 110));
  });
  testWidgets(
      'default warm cache retains all 56 small panel resources for immediate first paint',
      (tester) async {
    final image = await tinyImage(32);
    final pool =
        SharedEmojiPlayerPool(loader: (_, __) async => FakeCodec(image));
    final handles = List.generate(
        56,
        (i) => pool.subscribe(File('panel-default-$i.webp'), 32)
          ..setVisible(true));
    await tester.pump();
    expect(handles.every((h) => h.frame != null), isTrue);
    for (final h in handles) {
      h.dispose();
    }
    final reopened = List.generate(
        56, (i) => pool.subscribe(File('panel-default-$i.webp'), 32));
    try {
      expect(reopened.every((h) => h.frame != null), isTrue);
      expect(pool.diagnostics['idleEntries'], 56);
      expect(pool.diagnostics['totalFrameBytes'], 56 * 32 * 32 * 4);
      expect(pool.diagnostics['idleCodecCount'], lessThanOrEqualTo(8));
    } finally {
      for (final h in reopened) {
        h.dispose();
      }
      pool.dispose();
      image.dispose();
    }
  });
  testWidgets('oversized codec output is physically bounded before publication',
      (tester) async {
    await tester.runAsync(() async {
      final image = await tinyImage(256);
      final pool =
          SharedEmojiPlayerPool(loader: (_, __) async => FakeCodec(image));
      final handle = pool.subscribe(File('oversized.webp'), 96)
        ..setVisible(true);
      try {
        for (var i = 0; handle.frame == null && i < 100; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(handle.frame, isNotNull);
        expect(handle.frame!.width, 96);
        expect(handle.frame!.height, 96);
        expect(pool.diagnostics['decodedImageBytes'], 96 * 96 * 4);
      } finally {
        handle.dispose();
        pool.dispose();
        image.dispose();
      }
    });
  });
  testWidgets('pool stops immediately without a widget frame when app pauses',
      (tester) async {
    final image = await tinyImage();
    final codecs = <FakeCodec>[];
    final pool = SharedEmojiPlayerPool(loader: (_, __) async {
      final codec = FakeCodec(image);
      codecs.add(codec);
      return codec;
    });
    final handles = List.generate(6,
        (i) => pool.subscribe(File('lifecycle$i.webp'), 32)..setVisible(true));
    await tester.pump();
    expect(pool.diagnostics['activeEntries'], 6);
    pool.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(pool.diagnostics['activeEntries'], 0);
    expect(pool.diagnostics['decodedImageBytes'], 0);
    final frames = pool.diagnostics['framesEmitted'];
    await tester.pump(const Duration(milliseconds: 100));
    expect(pool.diagnostics['framesEmitted'], frames);
    expect(codecs.every((codec) => codec.disposed), isTrue);
    pool.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(pool.diagnostics['activeEntries'], 6);
    expect(codecs.length, 12);
    for (final handle in handles) {
      handle.dispose();
    }
    pool.dispose();
    image.dispose();
  });
  testWidgets(
      'all eight visible resources play; repeats share a timeline and decode bounds',
      (tester) async {
    final image = await tinyImage();
    final codecs = <FakeCodec>[];
    final sizes = <int>[];
    final pool = SharedEmojiPlayerPool(loader: (file, size) async {
      sizes.add(size);
      final codec = FakeCodec(image);
      codecs.add(codec);
      return codec;
    });
    final handles = List.generate(
        8, (i) => pool.subscribe(File('emoji$i.webp'), 31)..setVisible(true));
    final repeated = pool.subscribe(File('emoji0.webp'), 32)..setVisible(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(codecs.length, 8);
    expect(codecs.every((c) => c.calls >= 2), isTrue);
    expect(identical(handles.first.frame, repeated.frame), isTrue);
    expect(sizes.toSet(), {32});
    expect(pool.diagnostics['peakInFlight'], lessThanOrEqualTo(2));
    for (final handle in [...handles, repeated]) {
      handle.dispose();
    }
    expect(pool.diagnostics['activeEntries'], 0);
    expect(pool.diagnostics['idleEntries'], 8);
    pool.dispose();
    expect(codecs.every((c) => c.disposed), isTrue);
    image.dispose();
  });

  testWidgets(
      'hidden or disposed during pending startup releases the late codec',
      (tester) async {
    final image = await tinyImage();
    final pending = Completer<EmojiFrameCodec>();
    final codec = FakeCodec(image);
    final pool = SharedEmojiPlayerPool(loader: (_, __) => pending.future);
    final handle = pool.subscribe(File('pending.webp'), 999)..setVisible(true);
    handle.setVisible(false);
    handle.dispose();
    pending.complete(codec);
    await tester.pump();
    expect(codec.disposed, isTrue);
    expect(codec.calls, 0);
    expect(pool.diagnostics['activeEntries'], 0);
    expect(SharedEmojiPlayerPool.decodeSize(999), 256);
    pool.dispose();
    image.dispose();
  });

  testWidgets(
      'codec failure is observable and pressure releases retained images',
      (tester) async {
    final image = await tinyImage();
    final pool = SharedEmojiPlayerPool(loader: (file, _) async {
      if (file.path.contains('broken')) throw StateError('invalid codec');
      return FakeCodec(image);
    });
    final broken = pool.subscribe(File('broken.webp'), 32)..setVisible(true);
    final working = pool.subscribe(File('working.webp'), 32)..setVisible(true);
    await tester.pump();
    expect(broken.failed, isTrue);
    expect(working.frame, isNotNull);
    pool.didHaveMemoryPressure();
    expect(working.frame, isNull);
    expect(pool.diagnostics['decodedImageBytes'], 0);
    broken.dispose();
    working.dispose();
    pool.dispose();
    image.dispose();
    await tester.pump(const Duration(milliseconds: 150));
  });

  testWidgets(
      'pending frame finishes before codec disposal and never publishes to disposed consumer',
      (tester) async {
    final image = await tinyImage();
    final codec = PendingFrameCodec();
    final pool = SharedEmojiPlayerPool(loader: (_, __) async => codec);
    final handle = pool.subscribe(File('frame-pending.webp'), 32)
      ..setVisible(true);
    var notifications = 0;
    handle.addListener(() => notifications++);
    await tester.pump();
    handle.dispose();
    expect(codec.disposed, isFalse);
    codec.pending.complete(
        EmojiDecodedFrame(image.clone(), const Duration(milliseconds: 20)));
    await tester.pump();
    expect(codec.disposed, isTrue);
    expect(notifications, 0);
    expect(pool.diagnostics['decodedImageBytes'], 0);
    pool.dispose();
    image.dispose();
  });

  testWidgets(
      'frame advancement repaints without repeating layout; visibility releases and restarts',
      (tester) async {
    final image = await tinyImage();
    final codecs = <FakeCodec>[];
    final pool = SharedEmojiPlayerPool(loader: (_, __) async {
      final codec = FakeCodec(image);
      codecs.add(codec);
      return codec;
    });
    var layouts = 0;
    Widget fixture(bool visible) => MediaQuery(
        data: const MediaQueryData(devicePixelRatio: 3),
        child: Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
                child: CountLayouts(
                    onLayout: () => layouts++,
                    child: SharedEmojiImage(
                        file: File('paint.webp'),
                        size: 32,
                        visible: visible,
                        fallback: const SizedBox(),
                        pool: pool)))));
    await tester.pumpWidget(fixture(true));
    await tester.pump();
    final box = tester.getSize(find.byType(SharedEmojiImage));
    final baseline = layouts;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(codecs.single.calls, greaterThan(4));
    expect(layouts, baseline);
    expect(box, const Size(32, 32));
    expect(pool.diagnostics['decodeSizes'], [96]);
    await tester.pumpWidget(fixture(false));
    expect(pool.diagnostics['activeEntries'], 0);
    expect(codecs.first.disposed, isFalse);
    await tester.pumpWidget(fixture(true));
    await tester.pump();
    expect(codecs.length, 1);
    await tester.pumpWidget(const SizedBox());
    pool.dispose();
    image.dispose();
  });
}
