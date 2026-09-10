import 'dart:async';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';

Uint8List _bytes(int seed) => Uint8List.fromList([seed, seed, seed]);

void main() {
  test('seed owns its bytes and invalid replacement retains valid entry', () {
    final cache = MediaMemoryCache();
    final source = _bytes(7);
    final key = 'content:${sha256.convert(source)}';
    cache.put(key, source);
    source[0] = 0;
    final cached = cache.get(key)!;
    expect(cached, _bytes(7));
    expect(() => cached[0] = 0, throwsUnsupportedError);
    expect(() => cache.put(key, _bytes(8)), throwsFormatException);
    expect(cache.get(key), same(cached));
    expect(cache.totalBytes, 3);
  });

  test('old flight cannot repopulate or remove new flight after clear',
      () async {
    final cache = MediaMemoryCache();
    final oldSource = Completer<Uint8List>();
    final newSource = Completer<Uint8List>();
    final oldFlight = cache.putIfAbsent('event', () => oldSource.future);
    cache.clear();
    final newFlight = cache.putIfAbsent('event', () => newSource.future);
    oldSource.complete(_bytes(1));
    await oldFlight;
    expect(cache.get('event'), isNull);
    expect(cache.putIfAbsent('event', () => throw StateError('duplicate')),
        same(newFlight));
    newSource.complete(_bytes(2));
    expect(await newFlight, _bytes(2));
    expect(cache.get('event'), _bytes(2));
  });

  test('synchronous loader failure is retryable', () async {
    final cache = MediaMemoryCache();
    await expectLater(
        cache.putIfAbsent('event', () => throw StateError('fail')),
        throwsStateError);
    expect(await cache.putIfAbsent('event', () async => _bytes(1)), _bytes(1));
  });

  test('cache owns immutable verified bytes including the first load',
      () async {
    final cache = MediaMemoryCache();
    final source = _bytes(7);
    final key = 'content:${sha256.convert(source)}';
    final loaded = await cache.putIfAbsent(key, () async => source);
    source[0] = 0;
    expect(loaded, _bytes(7));
    expect(() => loaded[0] = 2, throwsUnsupportedError);
    expect(() => loaded.buffer.asUint8List()[0] = 2, throwsUnsupportedError);
    expect(cache.get(key), same(loaded));
  });

  test('wrong content is rejected before entering the cache', () async {
    final cache = MediaMemoryCache();
    final key = 'content:${sha256.convert(_bytes(7))}';
    expect(() => cache.put(key, _bytes(8)), throwsFormatException);
    await expectLater(
        cache.putIfAbsent(key, () async => _bytes(8)), throwsFormatException);
    expect(cache.totalBytes, 0);
    final recovered = await cache.putIfAbsent(key, () async => _bytes(7));
    expect(cache.get(key), same(recovered));
  });

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
