import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/contain_image_bubble.dart';

Uint8List largeEncodedGif(int marker) {
  final base =
      base64Decode('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7');
  return Uint8List.fromList([
    ...base.take(base.length - 1),
    0x21,
    0xfe,
    for (var i = 0; i < 512; i++) ...[255, ...List.filled(255, marker)],
    0,
    0x3b
  ]);
}

Future<(ImageStream, ImageStreamListener)> listenReady(
    ImageProvider provider) async {
  final stream = provider.resolve(ImageConfiguration.empty);
  final ready = Completer<void>();
  final listener = ImageStreamListener((info, _) {
    info.dispose();
    if (!ready.isCompleted) ready.complete();
  }, onError: (Object error, StackTrace? stack) {
    if (!ready.isCompleted) ready.completeError(error, stack);
  });
  stream.addListener(listener);
  await ready.future;
  return (stream, listener);
}

void main() {
  testWidgets(
      'reattaching during deferred eviction keeps the live image usable',
      (tester) async {
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
    await tester.runAsync(() async {
      final provider = boundedChatImageProvider(largeEncodedGif(9));
      final key = await provider.obtainKey(ImageConfiguration.empty);
      final first = await listenReady(provider);
      first.$1.removeListener(first.$2);
      final next = await listenReady(provider);
      await Future<void>.delayed(Duration.zero);
      expect(cache.statusForKey(key).live, isTrue);
      next.$1.removeListener(next.$2);
      await Future<void>.delayed(Duration.zero);
      expect(cache.statusForKey(key).keepAlive, isFalse);
    });
    cache.clear();
    cache.clearLiveImages();
    await tester.pump();
  });
  testWidgets('small previews retain their decoded first paint cache',
      (tester) async {
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
    await tester.runAsync(() async {
      final bytes = base64Decode(
          'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7');
      final provider = boundedChatImageProvider(bytes);
      final key = await provider.obtainKey(ImageConfiguration.empty);
      final loaded = await listenReady(provider);
      loaded.$1.removeListener(loaded.$2);
      await Future<void>.delayed(Duration.zero);
      expect(cache.statusForKey(key).keepAlive, isTrue);
    });
    cache.clear();
    cache.clearLiveImages();
    await tester.pump();
  });
  testWidgets(
      'real ImageCache does not retain large encoded GIF payloads after last consumer leaves',
      (tester) async {
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
    await tester.runAsync(() async {
      var retainedEncoded = 0;
      for (var i = 0; i < 24; i++) {
        final bytes = largeEncodedGif(i);
        final provider = boundedChatImageProvider(bytes);
        final key = await provider.obtainKey(ImageConfiguration.empty);
        final loaded = await listenReady(provider);
        loaded.$1.removeListener(loaded.$2);
        await Future<void>.delayed(Duration.zero);
        if (cache.statusForKey(key).keepAlive) retainedEncoded += bytes.length;
      }
      expect(cache.currentSizeBytes, lessThan(1024),
          reason: 'decoded 1px budget hides megabytes of encoded GIF data');
      expect(retainedEncoded, 0,
          reason:
              'inactive large MemoryImage keys must not pin original GIF bytes');
    });
    cache.clear();
    cache.clearLiveImages();
    await tester.pump();
  });
  testWidgets(
      'shared active consumers keep the same image until the last listener leaves',
      (tester) async {
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
    await tester.runAsync(() async {
      final provider = boundedChatImageProvider(largeEncodedGif(7));
      final key = await provider.obtainKey(ImageConfiguration.empty);
      final first = await listenReady(provider),
          second = await listenReady(provider);
      first.$1.removeListener(first.$2);
      await Future<void>.delayed(Duration.zero);
      expect(cache.statusForKey(key).live, isTrue);
      expect(cache.statusForKey(key).keepAlive, isTrue);
      second.$1.removeListener(second.$2);
      await Future<void>.delayed(Duration.zero);
      expect(cache.statusForKey(key).keepAlive, isFalse);
    });
    cache.clear();
    cache.clearLiveImages();
    await tester.pump();
  });
}
