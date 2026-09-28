import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:liuhetong_mobile/ui/moments/moment_media_cache.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final oldPaths = PathProviderPlatform.instance;
  const origin = 'https://moments.example.test';
  const video = '$origin/api/v1/moments/media/content/video-token';
  const poster = '$origin/api/v1/moments/media/content/poster-token';
  final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==');
  setUpAll(() async {
    final parent = await Directory(
            '../../docs/verification/artifacts/2026-09-28/ios-media-room-followup/moments/poster-tests')
        .absolute
        .create(recursive: true);
    final root = await parent.createTemp('cache-');
    PathProviderPlatform.instance = _Paths(root.path);
  });
  tearDownAll(() {
    PathProviderPlatform.instance = oldPaths;
  });

  test(
      'cross-device poster downloads only small image and renewed capability reuses cache',
      () async {
    var requests = 0;
    final client = MockClient((request) async {
      expect(request.url.path, endsWith('poster-token'));
      requests++;
      return http.Response.bytes(png, 200,
          headers: {'content-type': 'image/png'});
    });
    Future<List<int>?> load(String videoUrl, String posterUrl) =>
        MomentMediaCache.resolveVideoPoster(videoUrl,
            cacheKey: 'a' * 64,
            posterCacheKey: 'b' * 64,
            accountKey: 'matrix:poster-delivery',
            trustedOrigin: origin,
            posterUrl: posterUrl,
            client: client);
    expect(await load(video, poster), png);
    expect(await load('$video-renewed', '$poster-renewed'), png);
    expect(requests, 1);
  });

  test('simultaneous tiles share one small-poster request', () async {
    final started = Completer<void>(), release = Completer<void>();
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      started.complete();
      await release.future;
      return http.Response.bytes(png, 200,
          headers: {'content-type': 'image/png'});
    });
    Future<List<int>?> load() => MomentMediaCache.resolveVideoPoster(video,
        cacheKey: 'c' * 64,
        posterCacheKey: 'd' * 64,
        accountKey: 'matrix:poster-single-flight',
        trustedOrigin: origin,
        posterUrl: poster,
        client: client);
    final first = load(), second = load();
    await started.future;
    release.complete();
    expect(await first, png);
    expect(await second, png);
    expect(requests, 1);
  });

  test('untrusted poster never sends a request or downloads remote video',
      () async {
    var requests = 0;
    final bytes = await MomentMediaCache.resolveVideoPoster(video,
        cacheKey: 'e' * 64,
        posterCacheKey: 'f' * 64,
        accountKey: 'matrix:poster-host-check',
        trustedOrigin: origin,
        posterUrl: 'https://evil.test/api/v1/moments/media/content/poster',
        client: MockClient((_) async {
      requests++;
      return http.Response.bytes(png, 200);
    }));
    expect(bytes, isNull);
    expect(requests, 0);
  });

  test(
      'historical video with no poster and no local video performs zero network requests',
      () async {
    var requests = 0, extractions = 0;
    final bytes = await MomentMediaCache.resolveVideoPoster(video,
        cacheKey: '1' * 64,
        accountKey: 'matrix:poster-history',
        trustedOrigin: origin, client: MockClient((_) async {
      requests++;
      return http.Response.bytes(png, 200);
    }), extract: (_) async {
      extractions++;
      return png;
    });
    expect(bytes, isNull);
    expect(requests, 0);
    expect(extractions, 0);
  });

  test(
      'historical already-local video extracts poster without another video download',
      () async {
    const account = 'poster-local';
    final generation = MediaCache.accountGeneration(account);
    await MomentMediaCache.storeUploadedVideo(video, png,
        cacheKey: '2' * 64,
        accountKey: 'matrix:$account',
        trustedOrigin: origin,
        expectedAccountGeneration: generation,
        mimeType: 'video/mp4');
    var requests = 0, extractions = 0;
    final bytes = await MomentMediaCache.resolveVideoPoster(video,
        cacheKey: '2' * 64,
        accountKey: 'matrix:$account',
        trustedOrigin: origin, client: MockClient((_) async {
      requests++;
      return http.Response.bytes(png, 200);
    }), extract: (file) async {
      expect(await file.readAsBytes(), png);
      extractions++;
      return png;
    });
    expect(bytes, png);
    expect(requests, 0);
    expect(extractions, 1);
  });

  test('oversized streamed poster remains uncached', () async {
    final bytes = await MomentMediaCache.resolveVideoPoster(video,
        cacheKey: '3' * 64,
        posterCacheKey: '4' * 64,
        accountKey: 'matrix:poster-limit',
        trustedOrigin: origin,
        posterUrl: poster,
        client: MockClient((_) async => http.Response.bytes(
            List<int>.filled(512 * 1024 + 1, 0), 200,
            headers: {'content-type': 'image/png'})));
    expect(bytes, isNull);
    expect(
        await MomentMediaCache.cachedVideoPoster(video,
            cacheKey: '3' * 64,
            accountKey: 'matrix:poster-limit',
            trustedOrigin: origin),
        isNull);
  });
}

final class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String> getApplicationDocumentsPath() async => path;
  @override
  Future<String> getApplicationSupportPath() async => path;
  @override
  Future<String> getTemporaryPath() async => path;
}
