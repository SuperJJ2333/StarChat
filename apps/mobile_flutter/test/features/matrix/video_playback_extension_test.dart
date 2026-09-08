import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

final class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final Directory root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root.path;
}

// Container signature fixture; native decoding is verified by the iOS probe.
Uint8List _container(String brand) => Uint8List.fromList([
      0,
      0,
      0,
      24,
      ...'ftyp'.codeUnits,
      ...brand.codeUnits,
      0,
      0,
      0,
      0,
      ...brand.codeUnits,
      ...'mp42'.codeUnits,
    ]);

void main() {
  late Directory docs;
  late PathProviderPlatform original;
  const key = MediaCacheKey(roomId: '!room:example.test', eventId: r'$video');

  setUp(() async {
    original = PathProviderPlatform.instance;
    final artifacts = Directory('../../docs/verification/artifacts/2026-09-08');
    await artifacts.create(recursive: true);
    docs = await artifacts.createTemp('video-playback-');
    PathProviderPlatform.instance = _Paths(docs);
  });

  tearDown(() async {
    PathProviderPlatform.instance = original;
    await docs.delete(recursive: true);
  });

  test('MP4 playback receives container suffix and keeps one governed file',
      () async {
    final bytes = _container('isom');
    final file = await resolveCachedVideoFile(
      key: key,
      decrypt: () async => bytes,
      memoryCache: MediaMemoryCache(),
    );

    expect(file.path, endsWith('.mp4'),
        reason: 'AVFoundation rejects the same MP4 at an extensionless path');
    expect(await file.readAsBytes(), bytes);
    expect(await MediaCache.totalCachedBytes(), bytes.length);
    expect((await MediaCache.cached(key.roomId, key.eventId))?.path, file.path);
    final dataFiles = await docs
        .list(recursive: true)
        .where((entity) => entity is File && !entity.path.endsWith('.len'))
        .toList();
    expect(dataFiles, hasLength(1), reason: 'No second plaintext media copy');
  });

  test('legacy extensionless cache migrates without downloading and reopens',
      () async {
    final bytes = _container('qt  ');
    final legacy = await MediaCache.store(key.roomId, key.eventId, bytes);
    final file = await resolveCachedVideoFile(
      key: key,
      decrypt: () async => throw StateError('Cache hit must not decrypt'),
      memoryCache: MediaMemoryCache(),
    );
    expect(file.path, endsWith('.mov'));
    expect(await legacy.exists(), isFalse);
    expect(await File('${legacy.path}.len').exists(), isFalse);
    expect(await File('${file.path}.len').readAsString(), '${bytes.length}');

    final again = await resolveCachedVideoFile(
      key: key,
      decrypt: () async => throw StateError('Restart must use disk cache'),
      memoryCache: MediaMemoryCache(),
    );
    expect(again.path, file.path);
    expect(await MediaCache.totalCachedBytes(), bytes.length);
  });

  test('store after migration reuses typed file and its integrity metadata',
      () async {
    final bytes = _container('isom');
    await MediaCache.store(key.roomId, key.eventId, bytes);
    final prepared =
        await MediaCache.preparePlaybackFile(key.roomId, key.eventId);
    final stored = await MediaCache.store(key.roomId, key.eventId, bytes);
    expect(stored.path, prepared.path);
    expect(await stored.readAsBytes(), bytes);
    expect(await File('${stored.path}.len').readAsString(), '${bytes.length}');
    expect(await docs.list(recursive: true).where((e) => e is File).length, 2,
        reason: 'Only one media file and its length sidecar remain');
    expect(await MediaCache.totalCachedBytes(), bytes.length);
  });

  test('concurrent migration and store complete with one usable cache file',
      () async {
    final bytes = _container('isom');
    final storing = MediaCache.store(key.roomId, key.eventId, bytes);
    final prepared = await Future.wait([
      MediaCache.preparePlaybackFile(key.roomId, key.eventId),
      MediaCache.preparePlaybackFile(key.roomId, key.eventId),
    ]).timeout(const Duration(seconds: 5));
    await storing;
    expect(prepared.map((file) => file.path).toSet(), hasLength(1));
    expect(prepared.first.path, endsWith('.mp4'));
    expect(await prepared.first.readAsBytes(), bytes);
    expect(await docs.list(recursive: true).where((e) => e is File).length, 2);
  });

  test('migrated cache still detects truncation and redownloads', () async {
    final bytes = _container('isom');
    await MediaCache.store(key.roomId, key.eventId, bytes);
    final prepared =
        await MediaCache.preparePlaybackFile(key.roomId, key.eventId);
    await prepared.writeAsBytes([0]);
    expect(await MediaCache.cached(key.roomId, key.eventId), isNull);
    expect(await File('${prepared.path}.len').exists(), isFalse);
    var decryptions = 0;
    final recovered = await resolveCachedVideoFile(
      key: key,
      decrypt: () async {
        decryptions++;
        return bytes;
      },
      memoryCache: MediaMemoryCache(),
    );
    expect(decryptions, 1);
    expect(recovered.path, endsWith('.mp4'));
    expect(await recovered.readAsBytes(), bytes);
  });

  for (final bytes in [
    Uint8List.fromList([0, 1, 2]),
    _container('heic'),
  ]) {
    test('unknown or non-video container is not mislabeled (${bytes.length})',
        () async {
      final original = await MediaCache.store(key.roomId, key.eventId, bytes);
      final prepared =
          await MediaCache.preparePlaybackFile(key.roomId, key.eventId);
      expect(prepared.path, original.path);
      expect(await prepared.readAsBytes(), bytes);
    });
  }

  test('hostile identifiers stay inside the managed cache directory', () async {
    const hostile = MediaCacheKey(roomId: '../../outside', eventId: '../a.mp4');
    final prepared = await resolveCachedVideoFile(
      key: hostile,
      decrypt: () async => _container('isom'),
      memoryCache: MediaMemoryCache(),
    );
    final cacheRoot =
        await Directory('${docs.path}/chat-media').resolveSymbolicLinks();
    expect(await prepared.resolveSymbolicLinks(),
        startsWith('$cacheRoot${Platform.pathSeparator}'));
    expect(await MediaCache.totalCachedBytes(), 24);
  });
}
