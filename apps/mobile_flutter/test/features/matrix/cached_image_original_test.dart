import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:liuhetong_mobile/features/matrix/media_index.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:liuhetong_mobile/features/matrix/room_image_preview_cache.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  final bytes = Uint8List.fromList([1, 2, 3, 4]);
  final hash = sha256.convert(bytes).toString();
  MediaCacheKey key(String account, {String? content}) => MediaCacheKey(
      accountId: account,
      roomId: 'room',
      eventId: 'event',
      contentSha256: content ?? hash);
  setUp(() async {
    clearMediaMemoryCaches();
    SharedPreferences.setMockInitialValues({});
    final base = Directory(
        '../../docs/verification/artifacts/2026-10-03/mobile-ui-push-2196/task-2-disk-fixtures');
    await base.create(recursive: true);
    final scratch = await base.createTemp('case-');
    final index = MediaIndex(
        databasePath: '${scratch.absolute.path}/index.db',
        factory: databaseFactoryFfiNoIsolate);
    MediaIndex.overrideShared(index);
    final oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(scratch.absolute.path);
    addTearDown(() async {
      await index.close();
      MediaIndex.overrideShared(null);
      PathProviderPlatform.instance = oldPaths;
      await scratch.delete(recursive: true);
    });
  });
  test(
      'durable original probe reads existing bytes only and isolates account/content',
      () async {
    expect(await readCachedImageOriginal(key: key('a'), isCurrent: () => true),
        isNull);
    await MediaCache.store('room', 'event', bytes,
        accountId: 'a', contentSha256: hash);
    clearMediaMemoryCaches();
    expect(await readCachedImageOriginal(key: key('a'), isCurrent: () => true),
        bytes);
    expect(await readCachedImageOriginal(key: key('b'), isCurrent: () => true),
        isNull);
    expect(
        await readCachedImageOriginal(
            key: key('a', content: 'a' * 64), isCurrent: () => true),
        isNull);
  });
  test('lease revoked before or during durable read cannot publish bytes',
      () async {
    await MediaCache.store('room', 'event', bytes,
        accountId: 'a', contentSha256: hash);
    expect(await readCachedImageOriginal(key: key('a'), isCurrent: () => false),
        isNull);
    var checks = 0;
    expect(
        await readCachedImageOriginal(
            key: key('a'), isCurrent: () => ++checks == 1),
        isNull);
    expect(checks, greaterThan(1));
  });
  test('same-length corrupted durable original is rejected before display',
      () async {
    final file = await MediaCache.store('room', 'event', bytes,
        accountId: 'a', contentSha256: hash);
    await file.writeAsBytes([4, 3, 2, 1], flush: true);
    // The reader either sees a cache miss during integrity lookup or rejects
    // the actual read with a hash error. It must never return corrupt bytes.
    try {
      expect(
          await readCachedImageOriginal(key: key('a'), isCurrent: () => true),
          isNull);
    } on FormatException {
      // Correct integrity rejection.
    }
  });
  test('cleared account cannot restore a previously durable original',
      () async {
    await MediaCache.store('room', 'event', bytes,
        accountId: 'a', contentSha256: hash);
    await MediaCache.clearAccount('a');
    expect(await readCachedImageOriginal(key: key('a'), isCurrent: () => true),
        isNull);
  });
}
