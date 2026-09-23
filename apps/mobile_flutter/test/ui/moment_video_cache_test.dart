import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:liuhetong_mobile/ui/moments/moment_media_cache.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String> getTemporaryPath() async => root;
  @override
  Future<String> getApplicationSupportPath() async => root;
  @override
  Future<String> getApplicationDocumentsPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final oldPaths = PathProviderPlatform.instance;
  const origin = 'https://moments.example.test';
  const url = '$origin/api/v1/moments/media/content/token';
  setUpAll(() async {
    final root = Directory(path.normalize(path.absolute(
        '../../docs/verification/artifacts/2026-09-23/moments-video/cache-${DateTime.now().microsecondsSinceEpoch}')));
    await root.create(recursive: true);
    PathProviderPlatform.instance = _Paths(root.path);
  });
  tearDownAll(() {
    PathProviderPlatform.instance = oldPaths;
  });

  test(
      'video revisit and refreshed capability reuse verified account object, other account misses',
      () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response.bytes([1, 2, 3], 200,
          headers: {'content-type': 'video/mp4'});
    });
    Future<File> fetch(String account, String source) =>
        MomentMediaCache.videoFile(source,
            cacheKey: 'a' * 64,
            accountKey: account,
            trustedOrigin: origin,
            client: client);
    final first = await fetch('matrix:alice', url);
    final refreshed = await fetch('matrix:alice', '$url-rotated');
    expect(refreshed.path, first.path);
    expect(await refreshed.readAsBytes(), [1, 2, 3]);
    expect(requests, 1);
    await MomentMediaCache.videoFile(url,
        cacheKey: 'a' * 64,
        accountKey: 'matrix:alice',
        trustedOrigin: origin,
        client: client,
        refresh: true);
    expect(requests, 2,
        reason: 'explicit playback retry evicts the failed reference');
    await fetch('matrix:bob', url);
    expect(requests, 3);
  });

  test(
      'untrusted URL never fetches; oversized streaming response is not cached',
      () async {
    var requests = 0;
    final client = MockClient.streaming((_, __) async {
      requests++;
      return http.StreamedResponse(
          Stream.fromIterable([
            List.filled(20 * 1024 * 1024, 0),
            [1]
          ]),
          200,
          headers: {'content-type': 'video/mp4'});
    });
    await expectLater(
        MomentMediaCache.videoFile('https://evil.test/video',
            cacheKey: 'b' * 64,
            accountKey: 'matrix:alice',
            trustedOrigin: origin,
            client: client),
        throwsStateError);
    expect(requests, 0);
    await expectLater(
        MomentMediaCache.videoFile(url,
            cacheKey: 'b' * 64,
            accountKey: 'matrix:alice',
            trustedOrigin: origin,
            client: client),
        throwsStateError);
    final provider = MomentMediaCache.imageProvider(url,
        cacheKey: 'b' * 64, accountKey: 'matrix:alice', trustedOrigin: origin);
    expect(
        await MediaCache.cached('moments', provider.cacheKey!,
            accountId: 'alice'),
        isNull);
  });

  test('account clear fences a late download and retry can fetch again',
      () async {
    final gate = Completer<void>();
    final requested = Completer<void>();
    final client = MockClient((_) async {
      requested.complete();
      await gate.future;
      return http.Response.bytes([3, 4], 200,
          headers: {'content-type': 'video/mp4'});
    });
    final pending = MomentMediaCache.videoFile(url,
        cacheKey: 'c' * 64,
        accountKey: 'matrix:carol',
        trustedOrigin: origin,
        client: client);
    final failed = expectLater(pending, throwsStateError);
    await requested.future;
    await MediaCache.clearAccount('carol');
    final retry = MockClient((_) async => http.Response.bytes([3, 4], 200,
        headers: {'content-type': 'video/mp4'}));
    final fresh = MomentMediaCache.videoFile(url,
        cacheKey: 'c' * 64,
        accountKey: 'matrix:carol',
        trustedOrigin: origin,
        client: retry);
    gate.complete();
    await failed;
    final file = await fresh;
    expect(await file.readAsBytes(), [3, 4]);
  });
}
