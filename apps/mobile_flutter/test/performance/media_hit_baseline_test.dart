import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liuhetong_mobile/features/matrix/media_cache.dart';

void main() {
  test('known hash 2MiB payload cache hit CPU baseline', () async {
    final bytes =
        Uint8List.fromList(List.generate(2 * 1024 * 1024, (i) => i % 251));
    final digest = sha256.convert(bytes).toString();
    final cache = MediaMemoryCache();
    var loads = 0;
    final samples = <int>[];
    Uint8List? first;
    for (var i = 0; i < 51; i++) {
      final key = MediaCacheKey(
          accountId: 'synthetic',
          roomId: 'room-${i % 3}',
          eventId: 'event-$i',
          contentSha256: digest);
      final watch = Stopwatch()..start();
      final value = await cache.putIfAbsent(key.cacheId, () async {
        loads++;
        return bytes;
      });
      watch.stop();
      if (i > 0) samples.add(watch.elapsedMicroseconds);
      first ??= value;
      expect(value, same(first));
    }
    expect(loads, 1);
    expect(cache.totalBytes, bytes.length);
    samples.sort();
    // Encoded-byte cache CPU only: synthetic payload, no GIF codec/disk/network.
    // ignore: avoid_print
    print(jsonEncode({
      'scenario': 'known_hash_memory_hit',
      'runner': 'desktop_flutter_test_not_device',
      'payloadBytes': bytes.length,
      'samples': samples.length,
      'loaderCalls': loads,
      'retainedBytes': cache.totalBytes,
      'p50_us': samples[24],
      'p95_us': samples[47],
      'p99_us': samples[49],
    }));
  });
}
