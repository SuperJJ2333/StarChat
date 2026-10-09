import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:liuhetong_mobile/features/matrix/media_load_scheduler.dart';
import 'package:liuhetong_mobile/features/matrix/media_memory_budget.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/media_resource_policy.dart';

void main() {
  testWidgets('memory pressure reaches encoded cache owners and decode budget',
      (tester) async {
    final cache = PaintingBinding.instance.imageCache;
    final previousBytes = cache.maximumSizeBytes;
    final previousEntries = cache.maximumSize;
    var clearCalls = 0;
    final policy = MediaResourcePolicy(clearEncoded: () => clearCalls++);
    try {
      policy.install();
      policy.install();
      expect(cache.maximumSizeBytes, 64 * 1024 * 1024);
      tester.binding.handleMemoryPressure();
      expect(clearCalls, 1);
      policy.dispose();
      tester.binding.handleMemoryPressure();
      expect(clearCalls, 1);
    } finally {
      policy.dispose();
      cache.maximumSizeBytes = previousBytes;
      cache.maximumSize = previousEntries;
    }
  });
  testWidgets(
      'pressure preserves active media flight and trims optional encoded cache',
      (tester) async {
    final pending = Completer<Uint8List>(), started = Completer<void>();
    final lease = mediaLoadScheduler.request('pressure-visible-flight', () {
      started.complete();
      return pending.future;
    });
    final result = lease.value
        .then<Object>((value) => value, onError: (Object error) => error);
    await tester.pump();
    await started.future;
    videoMemoryCache.put('pressure-cache', Uint8List.fromList([1, 2, 3]));
    expect(sharedMediaMemoryBudget.totalBytes, greaterThan(0));
    final policy =
        MediaResourcePolicy(clearEncoded: trimOptionalMediaMemoryCaches)
          ..install();
    tester.binding.handleMemoryPressure();
    expect(videoMemoryCache.get('pressure-cache'), isNull);
    expect(sharedMediaMemoryBudget.totalBytes, 0);
    pending.complete(Uint8List.fromList([9, 8, 7]));
    await tester.pump();
    expect(await result, isA<Uint8List>());
    policy.dispose();
  });
  testWidgets('pressure retains live decoded image listeners', (tester) async {
    final cache = PaintingBinding.instance.imageCache;
    final provider = MemoryImage(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='));
    late ImageStream stream;
    late ImageStreamListener listener;
    await tester.runAsync(() async {
      final ready = Completer<void>();
      stream = provider.resolve(ImageConfiguration.empty);
      listener = ImageStreamListener((image, _) {
        image.dispose();
        if (!ready.isCompleted) ready.complete();
      });
      stream.addListener(listener);
      await ready.future;
    });
    final key = await provider.obtainKey(ImageConfiguration.empty);
    expect(cache.statusForKey(key).live, true);
    // Exercise the callback chain used by chat image consumers on explicit clear.
    registerDecodedMediaCacheClearer(cache.clearLiveImages);
    final policy =
        MediaResourcePolicy(clearEncoded: trimOptionalMediaMemoryCaches)
          ..install();
    tester.binding.handleMemoryPressure();
    expect(cache.statusForKey(key).live, true);
    stream.removeListener(listener);
    policy.dispose();
    cache.clear();
    cache.clearLiveImages();
  });
}
