import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';

Uint8List _bytes(int seed) => Uint8List.fromList([seed, seed, seed]);

void main() {
  test('putIfAbsent caches bytes and returns synchronously on hit', () async {
    final cache = MediaMemoryCache();
    var loads = 0;

    final first = await cache.putIfAbsent('evt-1', () async {
      loads++;
      return _bytes(1);
    });
    final second = await cache.putIfAbsent('evt-1', () async {
      loads++;
      return _bytes(2);
    });

    expect(loads, 1);
    expect(identical(first, second), isTrue, reason: '同实例命中图片解码缓存');
    expect(cache.get('evt-1'), same(first));
  });

  test('concurrent loads for the same event share one flight', () async {
    final cache = MediaMemoryCache();
    var loads = 0;
    Future<Uint8List> loader() async {
      loads++;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return _bytes(9);
    }

    final results = await Future.wait([
      cache.putIfAbsent('evt-2', loader),
      cache.putIfAbsent('evt-2', loader),
      cache.putIfAbsent('evt-2', loader),
    ]);

    expect(loads, 1);
    expect(results.every((bytes) => identical(bytes, results.first)), isTrue);
  });

  test('expired in-flight failures do not poison later loads', () async {
    final cache = MediaMemoryCache();
    await expectLater(
      cache.putIfAbsent('evt-3', () async => throw StateError('boom')),
      throwsA(isA<StateError>()),
    );

    final recovered = await cache.putIfAbsent('evt-3', () async => _bytes(3));
    expect(recovered, _bytes(3));
  });

  test('lru eviction bounds memory entries', () async {
    final cache = MediaMemoryCache(maxEntries: 2);
    await cache.putIfAbsent('a', () async => _bytes(1));
    await cache.putIfAbsent('b', () async => _bytes(2));
    cache.get('a'); // 访问 a，使其比 b 更新
    await cache.putIfAbsent('c', () async => _bytes(3));

    expect(cache.get('a'), isNotNull, reason: '最近访问的 a 应保留');
    expect(cache.get('b'), isNull, reason: '最久未用的 b 应被淘汰');
    expect(cache.get('c'), isNotNull);
  });
}
