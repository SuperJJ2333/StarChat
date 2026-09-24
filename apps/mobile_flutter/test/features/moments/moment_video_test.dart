import 'package:path/path.dart' as path;
import 'package:liuhetong_mobile/ui/moments/moment_media_cache.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'dart:io';
import 'package:liuhetong_mobile/features/moments/moment_image_preprocessor.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/moments/moment_composer_page.dart';
import 'package:liuhetong_mobile/features/moments/moment_draft_store.dart';
import 'package:liuhetong_mobile/features/moments/personal_moments_page.dart';
import 'package:liuhetong_mobile/features/moments/moment_models.dart';
import 'package:liuhetong_mobile/ui/moments/wechat_moment_tile.dart';
import 'package:liuhetong_mobile/ui/moments/moment_video_tile.dart';
import 'package:liuhetong_mobile/features/matrix/image_picker_page.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/matrix/gallery_video_preview.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache_metrics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('account clear fences an in-flight Moments video download', () async {
    final previousPaths = PathProviderPlatform.instance;
    final artifacts = await Directory(path.normalize(path.absolute(
        '../../docs/verification/artifacts/2026-09-24/group-moments-wallet-debug')))
        .create(recursive: true);
    final scratch = await artifacts.createTemp('moments-video-clear-');
    PathProviderPlatform.instance = _PosterPaths(scratch.path);
    const account = '@video-clear:example.test';
    const origin = 'https://example.test';
    const url = '$origin/api/v1/moments/media/content/clear-race';
    final cacheKey = 'd' * 64;
    final entered = Completer<void>();
    final release = Completer<void>();
    final client = MockClient((_) async {
      entered.complete();
      await release.future;
      return http.Response.bytes(Uint8List.fromList([1, 2, 3]), 200,
          headers: {'content-type': 'video/mp4'});
    });
    try {
      final scopedKey = MomentMediaCache.imageProvider(url,
              cacheKey: cacheKey,
              accountKey: 'matrix:$account',
              trustedOrigin: origin)
          .cacheKey!;
      final loading = MomentMediaCache.videoFile(url,
          cacheKey: cacheKey,
          accountKey: 'matrix:$account',
          trustedOrigin: origin,
          client: client);
      final assertion = expectLater(loading, throwsStateError);
      await entered.future.timeout(const Duration(seconds: 5));
      await MediaCache.clearAccount(account);
      final writesAfterClear = MediaCacheMetrics.diskBytesWritten;
      release.complete();
      await assertion;
      expect(MediaCacheMetrics.diskBytesWritten, writesAfterClear,
          reason: 'the revoked download must never write an account object');
      expect(await MediaCache.cached('moments', scopedKey, accountId: account),
          isNull);
    } finally {
      if (!release.isCompleted) release.complete();
      client.close();
      PathProviderPlatform.instance = previousPaths;
    }
  });

  testWidgets('renewed server draft uses only an existing account poster',
      (tester) async {
    final oldPaths = PathProviderPlatform.instance;
    final scratch = Directory(path.normalize(path.absolute(
        '../../docs/verification/artifacts/2026-09-24/group-moments-wallet-debug/draft-renewed-poster')));
    await tester.runAsync(() => scratch.create(recursive: true));
    PathProviderPlatform.instance = _PosterPaths(scratch.path);
    const account = '@draft-renewed:example.test';
    const origin = 'https://example.test';
    const first = '$origin/api/v1/moments/media/content/first';
    const renewed = '$origin/api/v1/moments/media/content/renewed';
    const unrelated = '$origin/api/v1/moments/media/content/unrelated';
    final key = 'a' * 64;
    final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');
    final oldStore = MomentDraftStores.shared;
    MomentDraftStores.shared = InMemoryMomentDraftStore(MomentDraftSnapshot(
        scope: 'matrix:$account',
        payload: {
          'text': '本地草稿',
          'video_urls': [first],
          'video_cache_keys': [key]
        },
        savedAt: DateTime.now()));
    var serverUrl = renewed;
    var serverKey = key;
    final session = SecureSessionStore(_Store());
    await session.saveSession(
        accessToken: 'a', refreshToken: 'r', matrixUserId: account);
    final api = BusinessApiClient(
        baseUri: Uri.parse(origin),
        sessionStore: session,
        client: MockClient((request) async {
          if (request.method == 'GET' && request.url.path.endsWith('/draft')) {
            return http.Response(
                jsonEncode({
                  'text': 'server draft',
                  'video_urls': [serverUrl],
                  'video_cache_keys': [serverKey]
                }),
                200);
          }
          throw StateError('Unexpected ${request.method} ${request.url}');
        }));
    try {
      await tester.runAsync(() => MomentMediaCache.storeVideoPoster(first, png,
          cacheKey: key,
          accountKey: 'matrix:$account',
          trustedOrigin: origin,
          expectedAccountGeneration: MediaCache.accountGeneration(account)));
      await tester.pumpWidget(CupertinoApp(home: MomentComposerPage(api: api)));
      await tester.pumpAndSettle();
      for (var i = 0; i < 100; i++) {
        final serverApplied =
            MomentDraftStores.shared!.read()!.payload['video_urls']
                    ?.toString() ==
                [renewed].toString();
        if (serverApplied && find.byType(Image).evaluate().isNotEmpty) break;
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
      }
      expect(MomentDraftStores.shared!.read()!.payload['video_urls'], [renewed]);
      expect(MomentDraftStores.shared!.read()!.payload['video_cache_keys'],
          [key]);
      expect(
          await tester.runAsync(() => MomentMediaCache.cachedVideoPoster(renewed,
              cacheKey: key,
              accountKey: 'matrix:$account',
              trustedOrigin: origin)),
          png);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);

      serverUrl = unrelated;
      serverKey = 'b' * 64;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(CupertinoApp(home: MomentComposerPage(api: api)));
      await tester.pumpAndSettle();
      for (var i = 0; i < 100; i++) {
        if (MomentDraftStores.shared!.read()!.payload['video_urls']
                ?.toString() ==
            [unrelated].toString()) {
          break;
        }
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
      }
      expect(MomentDraftStores.shared!.read()!.payload['video_urls'],
          [unrelated]);
      expect(MomentDraftStores.shared!.read()!.payload['video_cache_keys'],
          isNull,
          reason: 'an arbitrary server key without a local poster is ignored');
      expect(find.byType(Image), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox());
      MomentDraftStores.shared = oldStore;
      PathProviderPlatform.instance = oldPaths;
    }
  });

  testWidgets('saving draft locks deletion and publish until upload completes',
      (tester) async {
    final uploaded = Completer<void>();
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: SecureSessionStore(_Store()),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/uploads')) {
            return http.Response('{"id":"v"}', 201);
          }
          if (request.url.path.endsWith('/content')) {
            await uploaded.future;
            return http.Response('', 204);
          }
          if (request.url.path.endsWith('/complete')) {
            return http.Response(
                '{"media_url":"media://moments/u/v.mp4"}', 200);
          }
          return http.Response('{}', 200);
        }));
    await tester.pumpWidget(CupertinoApp(
        home: MomentComposerPage(api: api, initialImages: [
      XFile.fromData(Uint8List.fromList([1]), mimeType: 'video/mp4')
    ])));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-compose-cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存草稿'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final buttons = find.ancestor(
        of: find.byIcon(CupertinoIcons.clear_circled_solid),
        matching: find.byType(CupertinoButton));
    expect(tester.widget<CupertinoButton>(buttons).onPressed, isNull);
    expect(
        tester
            .widget<CupertinoButton>(
                find.byKey(const Key('moment-compose-publish')))
            .onPressed,
        isNull);
    uploaded.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'saved video draft restores account poster after URL renewal and removes it',
      (tester) async {
    final oldPaths = PathProviderPlatform.instance;
    final scratch = Directory(path.normalize(path.absolute(
        '../../docs/verification/artifacts/2026-09-23/feedback-2165-moments/poster-widget')));
    await tester.runAsync(() => scratch.create(recursive: true));
    PathProviderPlatform.instance = _PosterPaths(scratch.path);
    const account = '@draft-poster:example';
    const origin = 'https://example.test';
    const first = '$origin/api/v1/moments/media/content/first';
    const renewed = '$origin/api/v1/moments/media/content/renewed';
    final key = 'c' * 64;
    final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');
    var saved = false;
    final previousDraftStore = MomentDraftStores.shared;
    MomentDraftStores.shared = InMemoryMomentDraftStore();
    final sessions = SecureSessionStore(_Store());
    await sessions.saveSession(
        accessToken: 'a', refreshToken: 'r', matrixUserId: account);
    final api = BusinessApiClient(
        baseUri: Uri.parse(origin),
        sessionStore: sessions,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/draft')) {
            if (request.method == 'PUT') saved = true;
            return http.Response(
                jsonEncode(saved
                    ? {
                        'video_urls': [first],
                      }
                    : {}),
                200);
          }
          if (request.url.path.endsWith('/uploads')) {
            return http.Response('{"id":"v"}', 201);
          }
          if (request.url.path.endsWith('/complete')) {
            return http.Response(
                jsonEncode({'media_url': first, 'media_cache_key': key}), 200);
          }
          if (request.url.path.endsWith('/content') &&
              request.method == 'PUT') {
            return http.Response('', 204);
          }
          throw StateError(
              'Unexpected request: ${request.method} ${request.url}');
        }));
    try {
      await tester.pumpWidget(CupertinoApp(
          home: MomentComposerPage(
              api: api,
              galleryPicker: (_, __) async => (
                    photos: [
                      GalleryPhoto(
                          id: '1',
                          thumbnail: png,
                          isVideo: true,
                          mimeType: 'video/mp4',
                          originalBytes: () async => Uint8List.fromList([1]),
                          compressedBytes: () async => Uint8List(0))
                    ],
                    original: true,
                    flash: false
                  ))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('moment-pick-images')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('moment-compose-cancel')));
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(find.text('保存草稿')));
      for (var i = 0; i < 100 && !saved; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
      }
      await tester.pumpAndSettle();
      expect(saved, isTrue);
      expect(MomentDraftStores.shared!.read()!.payload['video_cache_keys'],
          [key]);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(CupertinoApp(home: MomentComposerPage(api: api)));
      await tester.pumpAndSettle();
      expect(MomentDraftStores.shared!.read()!.payload['video_cache_keys'],
          [key],
          reason: 'server draft omits local cache keys but must not erase them');
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      for (var i = 0; i < 100 && find.byType(Image).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
      }
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      await tester.runAsync(
          () => tester.tap(find.byIcon(CupertinoIcons.clear_circled_solid)));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(
            await MomentMediaCache.cachedVideoPoster(renewed,
                cacheKey: key,
                accountKey: 'matrix:$account',
                trustedOrigin: origin),
            isNull);
      });
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => MediaCache.clearAccount(account));
      MomentDraftStores.shared = previousDraftStore;
      PathProviderPlatform.instance = oldPaths;
    }
  });

  testWidgets(
      'mixed image video draft reopens and publishes with real request contract',
      (tester) async {
    final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');
    Map<String, dynamic> draft = {};
    final begins = <Map<String, dynamic>>[];
    final requests = <Map<String, dynamic>>[];
    Map<String, dynamic>? published;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: SecureSessionStore(_Store()),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/draft')) {
            if (request.method == 'PUT') {
              requests.add(
                  {'schema': 'DraftPayload', 'body': jsonDecode(request.body)});
              draft = jsonDecode(request.body)['payload'];
            }
            return http.Response(jsonEncode(draft), 200);
          }
          if (request.url.path.endsWith('/uploads')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            begins.add(body);
            requests.add({'schema': 'BeginUpload', 'body': body});
            return http.Response(
                jsonEncode({'id': begins.length.toString()}), 201);
          }
          if (request.url.path.endsWith('/content')) {
            return http.Response('', 204);
          }
          if (request.url.path.endsWith('/complete')) {
            return http.Response(
                jsonEncode({'media_url': 'media://moments/u/${begins.length}'}),
                200);
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/moments')) {
            published = jsonDecode(request.body);
            requests.add({'schema': 'CreateMoment', 'body': published});
          }
          return http.Response('{}', 200);
        }));
    await tester.pumpWidget(CupertinoApp(
        home: MomentComposerPage(
            api: api,
            imagePreprocessor:
                MomentImagePreprocessor.functional((bytes) async => bytes),
            galleryPicker: (_, __) async => (
                  photos: [
                    GalleryPhoto(
                        id: '123',
                        thumbnail: png,
                        isVideo: true,
                        mimeType: 'video/mp4',
                        originalBytes: () async =>
                            Uint8List.fromList([1, 2, 3]),
                        compressedBytes: () async => Uint8List(0)),
                    GalleryPhoto(
                        id: '456',
                        thumbnail: png,
                        originalBytes: () async => png,
                        compressedBytes: () async => png)
                  ],
                  original: true,
                  flash: false
                ))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-pick-images')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-compose-cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存草稿'));
    await tester.pumpAndSettle();
    expect(begins, hasLength(2));
    expect(begins.first['file_name'], 'moment-0.mp4');
    expect(draft['video_urls'], ['media://moments/u/1']);
    expect(draft['image_urls'], ['media://moments/u/2']);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pumpWidget(CupertinoApp(home: MomentComposerPage(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-compose-publish')));
    await tester.pumpAndSettle();
    expect(begins, hasLength(2));
    expect(published?['video_urls'], draft['video_urls']);
    expect(published?['image_urls'], draft['image_urls']);
    expect(
        requests,
        jsonDecode(File(
                '../../tests/business_api/moments/fixtures/composer_requests.json')
            .readAsStringSync()));
    final output = Platform.environment['MOMENT_CONTRACT_CAPTURE'];
    if (output != null) File(output).writeAsStringSync(jsonEncode(requests));
  });

  testWidgets('GIF composer uploads original animation with gif MIME',
      (tester) async {
    final gif = base64Decode(
        'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7');
    Map<String, dynamic>? begin;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: SecureSessionStore(_Store()),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/uploads')) {
            begin = jsonDecode(request.body);
            return http.Response('{"id":"gif"}', 201);
          }
          if (request.url.path.endsWith('/content')) {
            expect(request.bodyBytes, gif);
            expect(request.headers['content-type'], 'image/gif');
            return http.Response('', 204);
          }
          if (request.url.path.endsWith('/complete')) {
            return http.Response(
                '{"media_url":"media://moments/u/a.gif"}', 200);
          }
          return http.Response('{}', 200);
        }));
    await tester.pumpWidget(CupertinoApp(
        home: MomentComposerPage(
            api: api,
            imagePreprocessor: MomentImagePreprocessor.functional(
                (_) async => Uint8List.fromList([1])),
            initialImages: [
          XFile.fromData(gif, name: 'a.gif', mimeType: 'image/gif')
        ])));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-compose-publish')));
    await tester.pumpAndSettle();
    expect(begin?['mime_type'], 'image/gif');
    expect(begin?['file_name'], endsWith('.gif'));
  });

  testWidgets('album GIF stays animated and uploads without JPEG conversion',
      (tester) async {
    final gif = base64Decode(
        'R0lGODlhAgACAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAgACAAAIBgABCAQQEAAh+QQBCgABACwAAAAAAgACAIEAAP8AAAAAAAAAAAAIBgABCAQQEAA7');
    Map<String, dynamic>? begin;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: SecureSessionStore(_Store()),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/uploads')) {
            begin = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response('{"id":"gif"}', 201);
          }
          if (request.url.path.endsWith('/content')) {
            expect(request.bodyBytes, gif);
            expect(request.headers['content-type'], 'image/gif');
            return http.Response('', 204);
          }
          if (request.url.path.endsWith('/complete')) {
            return http.Response(
                '{"media_url":"media://moments/u/animated.gif"}', 200);
          }
          return http.Response('{}', 200);
        }));
    await tester.pumpWidget(CupertinoApp(
        home: MomentComposerPage(
            api: api,
            imagePreprocessor: MomentImagePreprocessor.functional(
                (_) async => throw StateError('GIF was converted')),
            galleryPicker: (_, __) async => (
                  photos: [
                    GalleryPhoto(
                        id: 'animated',
                        thumbnail: Uint8List(0),
                        mimeType: 'image/gif',
                        originalBytes: () async => gif,
                        compressedBytes: () async => Uint8List(0))
                  ],
                  original: true,
                  flash: false
                ))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-pick-images')));
    await tester.pumpAndSettle();
    final selected = tester.widget<Image>(find.byType(Image).first);
    expect(
        ((selected.image as ResizeImage).imageProvider as MemoryImage).bytes,
        gif);
    await tester.tap(find.byKey(const Key('moment-compose-publish')));
    await tester.pumpAndSettle();
    expect(begin?['mime_type'], 'image/gif');
    expect(begin?['file_name'], endsWith('.gif'));
  });

  testWidgets('published video reuses its uploaded bytes after URL renewal',
      (tester) async {
    final previousPaths = PathProviderPlatform.instance;
    final scratch = Directory(path.normalize(path.absolute(
        '../../docs/verification/artifacts/2026-09-24/group-moments-wallet-debug/video-upload-cache')));
    await tester.runAsync(() => scratch.create(recursive: true));
    PathProviderPlatform.instance = _PosterPaths(scratch.path);
    const account = '@video-cache:example.test';
    const origin = 'https://example.test';
    const uploadUrl = '$origin/api/v1/moments/media/content/upload-token';
    const renewedUrl = '$origin/api/v1/moments/media/content/feed-token';
    final cacheKey = 'd' * 64;
    final bytes = Uint8List.fromList(
        [0, 0, 0, 16, 102, 116, 121, 112, 109, 112, 52, 50, 0, 0, 0, 0]);
    var published = false;
    final session = SecureSessionStore(_Store());
    await session.saveSession(
        accessToken: 'access', refreshToken: 'refresh', matrixUserId: account);
    final api = BusinessApiClient(
        baseUri: Uri.parse(origin),
        sessionStore: session,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/draft')) {
            return http.Response('{}', 200);
          }
          if (request.url.path.endsWith('/uploads')) {
            return http.Response('{"id":"upload"}', 201);
          }
          if (request.method == 'PUT' &&
              request.url.path.endsWith('/content')) {
            expect(request.bodyBytes, bytes);
            return http.Response('', 204);
          }
          if (request.url.path.endsWith('/complete')) {
            return http.Response(
                jsonEncode({
                  'media_url': uploadUrl,
                  'media_cache_key': cacheKey,
                }),
                200);
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/moments')) {
            published = true;
            return http.Response('{"id":"posted"}', 201);
          }
          if (request.method == 'DELETE' &&
              request.url.path.endsWith('/draft')) {
            return http.Response('', 204);
          }
          throw StateError('Unexpected ${request.method} ${request.url}');
        }));
    try {
      await tester.pumpWidget(CupertinoApp(
          home: MomentComposerPage(api: api, initialImages: [
        XFile.fromData(bytes, name: 'clip.mp4', mimeType: 'video/mp4')
      ])));
      await tester.pumpAndSettle();
      await tester.runAsync(
          () => tester.tap(find.byKey(const Key('moment-compose-publish'))));
      for (var i = 0; i < 100 && !published; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
      }
      expect(published, isTrue);
      await tester.pump();
      final offline = MockClient((_) async => throw StateError('network used'));
      final playback = await tester.runAsync(() => MomentMediaCache.videoFile(
          renewedUrl,
          cacheKey: cacheKey,
          accountKey: 'matrix:$account',
          trustedOrigin: origin,
          client: offline));
      expect(await tester.runAsync(() => playback!.readAsBytes()), bytes);
      expect(playback!.path, endsWith('.mp4'));
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => MediaCache.clearAccount(account));
      PathProviderPlatform.instance = previousPaths;
    }
  });

  testWidgets('album video renders cached first frame before publish',
      (tester) async {
    final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');
    var frameLoads = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: SecureSessionStore(_Store()),
        client: MockClient((_) async => http.Response('{}', 200)));
    await tester.pumpWidget(CupertinoApp(
        home: MomentComposerPage(
            api: api,
            galleryPicker: (_, __) async => (
                  photos: [
                    GalleryPhoto(
                        id: '123',
                        thumbnail: Uint8List(0),
                        isVideo: true,
                        mimeType: 'video/mp4',
                        firstFrame: () async {
                          frameLoads++;
                          return png;
                        },
                        originalBytes: () async =>
                            Uint8List.fromList([1, 2, 3]),
                        compressedBytes: () async => Uint8List(0))
                  ],
                  original: true,
                  flash: false
                ))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-pick-images')));
    await tester.pumpAndSettle();
    expect(frameLoads, 1);
    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.play_circle), findsOneWidget);
  });

  testWidgets('feed video shows its account-cached poster before playback',
      (tester) async {
    final previousPaths = PathProviderPlatform.instance;
    final scratch = Directory(path.normalize(path.absolute(
        '../../docs/verification/artifacts/2026-09-24/group-moments-wallet-debug/video-tile-poster')));
    await tester.runAsync(() => scratch.create(recursive: true));
    PathProviderPlatform.instance = _PosterPaths(scratch.path);
    const account = '@tile-poster:example.test';
    const origin = 'https://example.test';
    const upload = '$origin/api/v1/moments/media/content/upload';
    const feed = '$origin/api/v1/moments/media/content/renewed';
    final cacheKey = 'e' * 64;
    final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');
    try {
      await tester.runAsync(() => MomentMediaCache.storeVideoPoster(upload, png,
          cacheKey: cacheKey,
          accountKey: 'matrix:$account',
          trustedOrigin: origin,
          expectedAccountGeneration: MediaCache.accountGeneration(account)));
      await tester.pumpWidget(CupertinoApp(
          home: MomentVideoTile(
              url: feed,
              cacheKey: cacheKey,
              accountKey: 'matrix:$account',
              trustedOrigin: origin)));
      for (var i = 0; i < 20 && find.byType(Image).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
      }
      expect(find.byType(Image), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.play_circle), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => MediaCache.clearAccount(account));
      PathProviderPlatform.instance = previousPaths;
    }
  });

  testWidgets('personal Moments list and detail play through viewer account cache',
      (tester) async {
    final previousPaths = PathProviderPlatform.instance;
    final scratch = Directory(path.normalize(path.absolute(
        '../../docs/verification/artifacts/2026-09-24/group-moments-wallet-debug/personal-video-cache')));
    await tester.runAsync(() => scratch.create(recursive: true));
    PathProviderPlatform.instance = _PosterPaths(scratch.path);
    const account = '@personal-viewer:example.test';
    const other = '@other-viewer:example.test';
    const origin = 'https://example.test';
    const upload = '$origin/api/v1/moments/media/content/upload';
    const feed = '$origin/api/v1/moments/media/content/renewed';
    final cacheKey = 'f' * 64;
    final bytes = Uint8List.fromList([
      0, 0, 0, 16, 102, 116, 121, 112, 109, 112, 52, 50, 0, 0, 0, 0
    ]);
    final itemJson = <String, dynamic>{
      'id': 'm1',
      'author': {'user_id': 'u1', 'nickname': 'Alice'},
      'text': '视频朋友圈',
      'image_urls': <String>[],
      'video_urls': [feed],
      'video_cache_keys': [cacheKey],
      'created_at': DateTime.now().toIso8601String(),
    };
    final session = SecureSessionStore(_Store());
    await session.saveSession(
        accessToken: 'access', refreshToken: 'refresh', matrixUserId: account);
    final api = BusinessApiClient(
        baseUri: Uri.parse(origin),
        sessionStore: session,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/moments/users/u1')) {
            return http.Response(jsonEncode({'items': [itemJson]}), 200);
          }
          if (request.url.path.endsWith('/moments/m1')) {
            return http.Response(jsonEncode(itemJson), 200);
          }
          return http.Response('{}', 200);
        }));
    final item = MomentItem.fromJson(itemJson);
    final offline = MockClient((_) async => throw StateError('network used'));
    try {
      await tester.runAsync(() => MomentMediaCache.storeUploadedVideo(
          upload, bytes,
          cacheKey: cacheKey,
          accountKey: 'matrix:$account',
          trustedOrigin: origin,
          expectedAccountGeneration: MediaCache.accountGeneration(account),
          mimeType: 'video/mp4'));
      await tester.pumpWidget(CupertinoApp(
          home: PersonalMomentsPage(
              api: api, userId: 'u1', displayName: 'Alice', initialItems: [item])));
      await tester.pumpAndSettle();
      final listTile = tester.widget<MomentVideoTile>(find.byType(MomentVideoTile));
      expect(listTile.accountKey, 'matrix:$account');
      expect(listTile.trustedOrigin, origin);
      final listPlayback = await tester.runAsync(() => MomentMediaCache.videoFile(
          listTile.url,
          cacheKey: listTile.cacheKey,
          accountKey: listTile.accountKey,
          trustedOrigin: listTile.trustedOrigin,
          client: offline));
      expect(await tester.runAsync(() => listPlayback!.readAsBytes()), bytes);

      tester.widget<WeChatMomentTile>(find.byType(WeChatMomentTile)).onOpen!();
      await tester.pumpAndSettle();
      expect(find.byType(PersonalMomentsPage), findsNothing);
      final detailTile = tester.widget<MomentVideoTile>(find.byType(MomentVideoTile));
      expect(detailTile.accountKey, 'matrix:$account');
      expect(detailTile.trustedOrigin, origin);
      final detailPlayback = await tester.runAsync(() => MomentMediaCache.videoFile(
          detailTile.url,
          cacheKey: detailTile.cacheKey,
          accountKey: detailTile.accountKey,
          trustedOrigin: detailTile.trustedOrigin,
          client: offline));
      expect(await tester.runAsync(() => detailPlayback!.readAsBytes()), bytes);

      await tester.pumpWidget(const SizedBox());
      await session.saveSession(
          accessToken: 'access', refreshToken: 'refresh', matrixUserId: other);
      await tester.pumpWidget(CupertinoApp(
          home: PersonalMomentsPage(
              api: api, userId: 'u1', displayName: 'Alice', initialItems: [item])));
      await tester.pumpAndSettle();
      final otherTile = tester.widget<MomentVideoTile>(find.byType(MomentVideoTile));
      expect(otherTile.accountKey, 'matrix:$other');
      final otherAccountNeededNetwork = await tester.runAsync(() async {
        try {
          await MomentMediaCache.videoFile(otherTile.url,
              cacheKey: otherTile.cacheKey,
              accountKey: otherTile.accountKey,
              trustedOrigin: otherTile.trustedOrigin,
              client: offline);
          return false;
        } on StateError {
          return true;
        }
      });
      expect(otherAccountNeededNetwork, isTrue,
          reason: 'another account must not read the first account video');

      await tester.pumpWidget(CupertinoApp(
          home: PersonalMomentsPage(
              api: api,
              identityCache:
                  ProfileRepository(api, accountKey: 'matrix:$account'),
              userId: 'u1',
              displayName: 'Alice',
              initialItems: [item])));
      await tester.pumpAndSettle();
      expect(tester.widget<MomentVideoTile>(find.byType(MomentVideoTile)).accountKey,
          isNull,
          reason: 'a stale identity projection cannot authorize new-account media');
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => MediaCache.clearAccount(account));
      await tester.runAsync(() => MediaCache.clearAccount(other));
      PathProviderPlatform.instance = previousPaths;
    }
  });

  testWidgets('pending upload disables attachment deletion', (tester) async {
    final uploaded = Completer<void>();
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: SecureSessionStore(_Store()),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/media/uploads')) {
            return http.Response('{"id":"pending"}', 201);
          }
          if (request.method == 'PUT') {
            await uploaded.future;
            return http.Response('', 204);
          }
          if (request.url.path.endsWith('/complete')) {
            return http.Response(
                '{"media_url":"media://moments/u/video.mp4"}', 200);
          }
          return http.Response('{}', 200);
        }));
    await tester.pumpWidget(CupertinoApp(
        home: MomentComposerPage(api: api, initialImages: [
      XFile.fromData(Uint8List.fromList([1, 2, 3]),
          name: 'video.mp4', mimeType: 'video/mp4')
    ])));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-compose-publish')));
    await tester.pump();
    final buttons = find.ancestor(
        of: find.byIcon(CupertinoIcons.clear_circled_solid),
        matching: find.byType(CupertinoButton));
    expect(buttons, findsOneWidget);
    expect(tester.widget<CupertinoButton>(buttons).onPressed, isNull);
    uploaded.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('gallery photo with missing thumbnail uses loaded image bytes',
      (tester) async {
    final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: SecureSessionStore(_Store()),
        client: MockClient((_) async => http.Response('{}', 200)));
    await tester.pumpWidget(CupertinoApp(
        home: MomentComposerPage(
            api: api,
            galleryPicker: (_, __) async => (
                  photos: [
                    GalleryPhoto(
                        id: 'photo',
                        thumbnail: Uint8List(0),
                        mimeType: 'image/png',
                        originalBytes: () async => png,
                        compressedBytes: () async => png)
                  ],
                  original: true,
                  flash: false
                ))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-pick-images')));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'pending gallery bytes lock publish until selected media is ready',
      (tester) async {
    final bytes = Completer<Uint8List>();
    var publishes = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: SecureSessionStore(_Store()),
        client: MockClient((request) async {
          if (request.method == 'POST') publishes++;
          return http.Response('{}', 200);
        }));
    await tester.pumpWidget(CupertinoApp(
        home: MomentComposerPage(
            api: api,
            galleryPicker: (_, __) async => (
                  photos: [
                    GalleryPhoto(
                        id: 'slow',
                        thumbnail: Uint8List(0),
                        isVideo: true,
                        mimeType: 'video/mp4',
                        originalBytes: () => bytes.future,
                        compressedBytes: () => bytes.future)
                  ],
                  original: true,
                  flash: false
                ))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoTextField).first, 'message');
    await tester.tap(find.byKey(const Key('moment-pick-images')));
    await tester.pump();
    expect(
        tester
            .widget<CupertinoButton>(
                find.byKey(const Key('moment-compose-publish')))
            .onPressed,
        isNull);
    expect(publishes, 0);
    bytes.complete(Uint8List.fromList([1, 2, 3]));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<CupertinoButton>(
                find.byKey(const Key('moment-compose-publish')))
            .onPressed,
        isNotNull);
  });
  testWidgets(
      'album entry routes to shared mixed gallery and cancellation returns',
      (tester) async {
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: SecureSessionStore(_Store()),
        client: MockClient((_) async => http.Response('{}', 200)));
    await tester.pumpWidget(CupertinoApp(home: MomentComposerPage(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('相册'), findsOneWidget);
    await tester.tap(find.byKey(const Key('moment-pick-images')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final gallery =
        tester.widget<ImagePickerPage>(find.byType(ImagePickerPage));
    expect(gallery.photosOnly, isFalse);
    expect(gallery.maxCount, 9);
    Navigator.of(tester.element(find.byType(ImagePickerPage))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(MomentComposerPage), findsOneWidget);
  });

  testWidgets('oversized album video is rejected before reading its bytes',
      (tester) async {
    var reads = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: SecureSessionStore(_Store()),
        client: MockClient((_) async => http.Response('{}', 200)));
    await tester.pumpWidget(CupertinoApp(
        home: MomentComposerPage(
            api: api,
            galleryPicker: (_, __) async => (
                  photos: [
                    GalleryPhoto(
                        id: 'large',
                        thumbnail: Uint8List(0),
                        isVideo: true,
                        mimeType: 'video/mp4',
                        originalSizeBytes: () async => 20 * 1024 * 1024 + 1,
                        originalBytes: () async {
                          reads++;
                          return Uint8List(1);
                        },
                        compressedBytes: () async => Uint8List(1))
                  ],
                  original: true,
                  flash: false,
                ))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-pick-images')));
    await tester.pumpAndSettle();
    expect(reads, 0);
    expect(find.text('视频大小不能超过20MB'), findsOneWidget);
  });

  testWidgets('restored draft publishes video reference without upload',
      (tester) async {
    Map<String, dynamic>? published;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: SecureSessionStore(_Store()),
        client: MockClient((request) async {
          if (request.method == 'GET' && request.url.path.endsWith('/draft')) {
            return http.Response(
                jsonEncode({
                  'text': 'draft',
                  'visibility': 'SELF',
                  'video_urls': ['media://moments/u/saved.mp4']
                }),
                200);
          }
          if (request.method == 'POST') {
            expect(request.url.path, '/api/v1/moments');
            published = jsonDecode(request.body) as Map<String, dynamic>;
          }
          return http.Response('{}', 200);
        }));
    await tester.pumpWidget(CupertinoApp(home: MomentComposerPage(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-compose-publish')));
    await tester.pumpAndSettle();
    expect(published?['video_urls'], ['media://moments/u/saved.mp4']);
    expect(published?['visibility'], 'SELF');
  });

  testWidgets(
      'shared viewer mode hides gallery selection and offers failure retry',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(
        home: GalleryVideoPreviewPage(
            viewerOnly: true,
            loadRendition: () async => throw StateError('offline'),
            thumbnailBytes: Uint8List(0),
            duration: null,
            selected: false,
            onToggle: () {})));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('gallery-video-select')), findsNothing);
    expect(find.byKey(const Key('gallery-video-retry')), findsOneWidget);
    expect(find.text('视频加载失败，请返回刷新或重试'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets('video DTO survives reaction copy and renders a play entry',
      (tester) async {
    final item = MomentItem.fromJson({
      'id': 'v',
      'author': {'user_id': 'u', 'nickname': '用户'},
      'text': '',
      'image_urls': [],
      'video_urls': ['https://example.test/video'],
      'video_cache_keys': ['a' * 64],
    }).copyWith(liked: true);
    await tester.pumpWidget(CupertinoApp(home: WeChatMomentTile(item: item)));
    expect(find.text('播放视频'), findsOneWidget);
  });

  testWidgets(
      'composer uploads video without image conversion and retries publish without reupload',
      (tester) async {
    var uploads = 0;
    var publishes = 0;
    final publishKeys = <String?>[];
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://example.test'),
      sessionStore: SecureSessionStore(_Store()),
      client: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/moments/draft')) return http.Response('{}', 200);
        if (path.endsWith('/moments/media/uploads')) {
          uploads++;
          expect(jsonDecode(request.body)['mime_type'], 'video/mp4');
          expect(jsonDecode(request.body)['file_name'], isNotEmpty);
          return http.Response('{"id":"v"}', 201);
        }
        if (path.endsWith('/content')) {
          expect(request.bodyBytes, [0, 0, 0, 16, 102, 116, 121, 112]);
          return http.Response('', 204);
        }
        if (path.endsWith('/complete')) {
          return http.Response(
              '{"status":"COMPLETED","media_url":"media://moments/u/v.mp4"}',
              200);
        }
        if (path.endsWith('/moments')) {
          publishes++;
          publishKeys.add(request.headers['Idempotency-Key']);
          final payload = jsonDecode(request.body);
          expect(payload['image_urls'], isEmpty);
          expect(payload['video_urls'], ['media://moments/u/v.mp4']);
          return publishes == 1
              ? http.Response(
                  '{"error":{"code":"RETRY","message":"retry"}}', 503)
              : http.Response('{}', 201);
        }
        return http.Response('{}', 200);
      }),
    );
    await tester.pumpWidget(CupertinoApp(
        home: MomentComposerPage(api: api, initialImages: [
      XFile.fromData(Uint8List.fromList([0, 0, 0, 16, 102, 116, 121, 112]),
          name: 'v.mp4', mimeType: 'video/mp4'),
    ])));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-compose-publish')));
    await tester.pumpAndSettle();
    expect(uploads, 1);
    await tester.tap(find.byKey(const Key('moment-compose-publish')));
    await tester.pumpAndSettle();
    expect(uploads, 1);
    expect(publishes, 2);
    expect(publishKeys[0], isNotNull);
    expect(publishKeys[1], publishKeys[0]);
  });
}

class _Store implements SecureKeyValueStore {
  final _values = <String, String>{};
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

class _PosterPaths extends PathProviderPlatform {
  _PosterPaths(this.path);
  final String path;
  @override
  Future<String> getApplicationDocumentsPath() async => path;
  @override
  Future<String> getTemporaryPath() async => path;
  @override
  Future<String> getApplicationSupportPath() async => path;
}
