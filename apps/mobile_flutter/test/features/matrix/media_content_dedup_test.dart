import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

void main() {
  setUp(() async {
    final root = await Directory(
            '../../docs/verification/artifacts/2026-09-09/redmi-polish')
        .create(recursive: true);
    final dir = await root.createTemp('media-test-');
    PathProviderPlatform.instance = _Paths(dir.path);
    addTearDown(() => dir.delete(recursive: true));
  });
  test('identical decrypted content across rooms occupies one physical object',
      () async {
    final files = await Future.wait([
      MediaCache.store('room-a', 'image-a', Uint8List.fromList([1, 2, 3])),
      MediaCache.store('room-b', 'image-b', Uint8List.fromList([1, 2, 3])),
    ]);
    expect(files[0].path, files[1].path);
    expect(await MediaCache.totalCachedBytes(), 3);
    expect((await MediaCache.cached('room-b', 'image-b'))!.path, files[0].path);
  });
  test(
      'upgrade removes only legacy managed media without adopting another account',
      () async {
    final docs =
        await PathProviderPlatform.instance.getApplicationDocumentsPath();
    final legacy = await Directory('$docs/chat-media/_room_ab12cd34')
        .create(recursive: true);
    await File('${legacy.path}/event').writeAsBytes([1, 2]);
    final fresh = await MediaCache.store(
        'room', 'event', Uint8List.fromList([3]),
        accountId: 'alice');
    await MediaCache.discardLegacyCache();
    expect(await legacy.exists(), isFalse);
    expect(await fresh.exists(), isTrue);
  });
  test('concurrent media consumers share download and decoded byte identity',
      () async {
    const key = MediaCacheKey(roomId: 'room', eventId: 'image');
    var calls = 0;
    final gate = Completer<Uint8List>();
    Future<Uint8List> decrypt() {
      calls++;
      return gate.future;
    }

    final a = loadMediaWithCache(key, decrypt);
    final b = loadMediaWithCache(key, decrypt);
    gate.complete(Uint8List.fromList([4, 5]));
    final bytes = await Future.wait([a, b]);
    expect(calls, 1);
    expect(identical(bytes[0], bytes[1]), isTrue);
  });
  test('logout before path lookup finishes prevents the old load starting',
      () async {
    var downloads = 0;
    final pending = loadMediaWithCache(
        const MediaCacheKey(accountId: 'alice', roomId: 'r', eventId: 'e'),
        () async {
      downloads++;
      return Uint8List.fromList([1]);
    });
    clearMediaMemoryCaches();
    await expectLater(pending, throwsStateError);
    expect(downloads, 0);
  });
  test('accounts never share object or memory despite matching event and bytes',
      () async {
    const a =
        MediaCacheKey(accountId: 'alice', roomId: 'room', eventId: 'event');
    const b = MediaCacheKey(accountId: 'bob', roomId: 'room', eventId: 'event');
    var calls = 0;
    Future<Uint8List> decrypt() async {
      calls++;
      return Uint8List.fromList([8, 9]);
    }

    final first = await loadMediaWithCache(a, decrypt);
    final second = await loadMediaWithCache(b, decrypt);
    expect(calls, 2);
    expect(identical(first, second), isFalse);
    final af = await MediaCache.cached('room', 'event', accountId: 'alice');
    final bf = await MediaCache.cached('room', 'event', accountId: 'bob');
    expect(af!.path, isNot(bf!.path));
  });
  test('known authenticated source shares concurrent and later room references',
      () async {
    var calls = 0;
    Future<Uint8List> decrypt() async {
      calls++;
      return Uint8List.fromList([6, 7]);
    }

    MediaCacheKey key(String room) => MediaCacheKey(
        accountId: 'alice',
        roomId: room,
        eventId: room,
        sourceIdentity: 'mxc + full encryption descriptor');
    final values = await Future.wait([
      loadMediaWithCache(key('a'), decrypt),
      loadMediaWithCache(key('b'), decrypt)
    ]);
    final third = await loadMediaWithCache(key('c'), decrypt);
    expect(calls, 1);
    expect(identical(values.first, values.last), isTrue);
    expect(identical(values.first, third), isTrue);
    final a = await MediaCache.cached('a', 'a', accountId: 'alice');
    final c = await MediaCache.cached('c', 'c', accountId: 'alice');
    expect(a!.path, c!.path);
  });
  test('independent encrypted sources decrypt once each then share bytes',
      () async {
    var calls = 0;
    Future<Uint8List> decrypt() async {
      calls++;
      return Uint8List.fromList([11, 12]);
    }

    final a = await loadMediaWithCache(
        const MediaCacheKey(
            roomId: 'a', eventId: 'a', sourceIdentity: 'cipher-a'),
        decrypt);
    final b = await loadMediaWithCache(
        const MediaCacheKey(
            roomId: 'b', eventId: 'b', sourceIdentity: 'cipher-b'),
        decrypt);
    expect(calls, 2);
    expect(identical(a, b), isTrue);
    expect(await MediaCache.totalCachedBytes(), 2);
  });
  test('clear while decrypting rejects stale completion without caching bytes',
      () async {
    final gate = Completer<Uint8List>();
    final entered = Completer<void>();
    final load =
        loadMediaWithCache(const MediaCacheKey(roomId: 'r', eventId: 'e'), () {
      entered.complete();
      return gate.future;
    });
    await entered.future;
    clearMediaMemoryCaches();
    final failure = expectLater(load, throwsStateError);
    gate.complete(Uint8List.fromList([1]));
    await failure;
    expect(await MediaCache.totalCachedBytes(), 0);
  });
  test('source identity includes encryption keys and canonicalizes map order',
      () {
    final a = {
      'file': {
        'url': 'mxc://server/a',
        'key': {'k': 'secret', 'kty': 'oct'},
        'iv': 'iv',
        'hashes': {'sha256': 'cipherhash'}
      }
    };
    final b = {
      'file': {
        'hashes': {'sha256': 'cipherhash'},
        'iv': 'iv',
        'key': {'kty': 'oct', 'k': 'secret'},
        'url': 'mxc://server/a'
      }
    };
    expect(matrixMediaSourceIdentity(a), matrixMediaSourceIdentity(b));
    b['file']!['iv'] = 'different';
    expect(matrixMediaSourceIdentity(a), isNot(matrixMediaSourceIdentity(b)));
    expect(
        matrixMediaSourceIdentity({
          'file': {'url': 'mxc://server/a'}
        }),
        isNull);
    expect(matrixMediaSourceIdentity({'url': 'mxc://server/a'}), isNotNull);
    expect(
        matrixMediaSourceIdentity({
          'info': {'thumbnail_url': 'mxc://server/a'}
        }, thumbnail: true),
        isNot(matrixMediaSourceIdentity({'url': 'mxc://server/a'})));
  });
}
