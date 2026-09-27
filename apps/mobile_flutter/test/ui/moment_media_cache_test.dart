import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:liuhetong_mobile/ui/moments/moment_media_cache.dart';
import 'package:liuhetong_mobile/ui/moments/moment_thumbnail_provider.dart';
import 'package:liuhetong_mobile/ui/moments/moment_image_viewer_page.dart';
import 'package:liuhetong_mobile/ui/moments/wechat_moment_image_grid.dart';
import 'package:liuhetong_mobile/ui/moments/wechat_moment_viewer.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _RealHttp extends HttpOverrides {}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String> getTemporaryPath() async => path;
  @override
  Future<String> getApplicationSupportPath() async => path;
  @override
  Future<String> getApplicationDocumentsPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final oldPaths = PathProviderPlatform.instance;
  // Directory.absolute retains '..'; normalize before Windows directory
  // enumeration so a worktree prefix does not inflate the native search path.
  final scratch = Directory(path.normalize(path.absolute(
      '../../docs/verification/artifacts/2026-09-23/remaining-optimizations/media/cache-${DateTime.now().microsecondsSinceEpoch}')));
  final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');
  setUpAll(() async {
    await scratch.create(recursive: true);
    PathProviderPlatform.instance = _Paths(scratch.path);
  });
  tearDownAll(() async {
    await MomentMediaCache.manager.dispose();
    PathProviderPlatform.instance = oldPaths;
  });

  test('rotating signed paths share memory and disk but fetch full URL',
      () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      server.listen((request) async {
        requests.add(request.uri.toString());
        request.response.headers.set('cache-control', 'max-age=3600');
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(png);
        await request.response.close();
      });
      try {
        final origin = 'http://127.0.0.1:${server.port}';
        final prefix = '$origin/api/v1/profile/avatar/content';
        const key =
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        final first = MomentMediaCache.imageProvider(
            '$prefix/signed-A?expires_in=300',
            cacheKey: key,
            accountKey: 'matrix:alice',
            trustedOrigin: origin);
        final refreshed = MomentMediaCache.imageProvider(
            '$prefix/signed-B?expires_in=604800',
            cacheKey: key,
            accountKey: 'matrix:alice',
            trustedOrigin: origin);
        await imageReady(first.resolve(ImageConfiguration.empty));
        expect(first, refreshed);
        expect(
            PaintingBinding.instance.imageCache.containsKey(refreshed), isTrue);
        await first.evict();
        await imageReady(refreshed.resolve(ImageConfiguration.empty));
        expect(requests,
            ['/api/v1/profile/avatar/content/signed-A?expires_in=300']);
        // A different origin cannot collide even with an identical server key.
        final otherOrigin = MomentMediaCache.imageProvider(
            'https://other.example/signed-A',
            cacheKey: key,
            accountKey: 'matrix:alice',
            trustedOrigin: origin);
        expect(otherOrigin.cacheKey, startsWith('moments-url-account-v1:'));
        expect(otherOrigin.cacheKey, isNot(first.cacheKey));
        expect(
            MomentMediaCache.imageProvider('$prefix/signed-A',
                    cacheKey: key,
                    accountKey: 'matrix:bob',
                    trustedOrigin: origin)
                .cacheKey,
            isNot(first.cacheKey));
        expect(
            MomentMediaCache.imageProvider('$origin/arbitrary',
                    cacheKey: key,
                    accountKey: 'matrix:alice',
                    trustedOrigin: origin)
                .cacheKey,
            startsWith('moments-url-account-v1:'));
        expect(
            MomentMediaCache.imageProvider('$prefix/signed-A',
                    cacheKey: key, trustedOrigin: origin)
                .cacheKey,
            isNull);
        const changed =
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
        final replacement = MomentMediaCache.imageProvider(
            '$prefix/replacement?signature=new',
            cacheKey: changed,
            accountKey: 'matrix:alice',
            trustedOrigin: origin);
        await imageReady(replacement.resolve(ImageConfiguration.empty));
        expect(requests, [
          '/api/v1/profile/avatar/content/signed-A?expires_in=300',
          '/api/v1/profile/avatar/content/replacement?signature=new'
        ]);
        // Missing, malformed and legacy identities never collapse URL variants.
        final fallbackA = MomentMediaCache.imageProvider('$origin/unknown?v=A');
        final fallbackB = MomentMediaCache.imageProvider('$origin/unknown?v=B');
        expect(fallbackA, isNot(fallbackB));
        expect(fallbackA.cacheKey, isNull);
        expect(
            MomentMediaCache.imageProvider('$origin/unknown', cacheKey: 'bad')
                .cacheKey,
            isNull);
      } finally {
        await server.close(force: true);
      }
    }, _RealHttp());
  });

  test('rotating Moments media capabilities use the account-scoped cache key',
      () {
    const origin = 'https://media.example.test';
    const key =
        'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
    final first = MomentMediaCache.imageProvider(
        '$origin/api/v1/moments/media/content/signed-A?expires_in=300',
        cacheKey: key,
        accountKey: 'matrix:alice',
        trustedOrigin: origin);
    final refreshed = MomentMediaCache.imageProvider(
        '$origin/api/v1/moments/media/content/signed-B?expires_in=604800',
        cacheKey: key,
        accountKey: 'matrix:alice',
        trustedOrigin: origin);

    expect(first, refreshed);
    expect(first.cacheKey, startsWith('moments-origin-account-v1:'));
    expect(
        MomentMediaCache.imageProvider(
            '$origin/api/v1/moments/media/content/signed-A',
            cacheKey: key,
            accountKey: 'matrix:bob',
            trustedOrigin: origin),
        isNot(first));
    expect(
        MomentMediaCache.imageProvider(
                '$origin/api/v1/moments/media/uploads/signed-A',
                cacheKey: key,
                accountKey: 'matrix:alice',
                trustedOrigin: origin)
            .cacheKey,
        startsWith('moments-url-account-v1:'));
  });

  test('authorized Moments download aliases an existing chat content object',
      () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(png);
        await request.response.close();
      });
      const account = '@alice:example.test';
      const bobAccount = '@bob:example.test';
      try {
        final origin = 'http://127.0.0.1:${server.port}';
        const pageAccount = 'matrix:@alice:example.test';
        const bobPageAccount = 'matrix:@bob:example.test';
        const reference =
            'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
        final chat =
            await MediaCache.store('chat', 'event', png, accountId: account);
        final first = MomentMediaCache.imageProvider(
            '$origin/api/v1/moments/media/content/signed-A',
            cacheKey: reference,
            accountKey: pageAccount,
            trustedOrigin: origin);
        await imageReady(first.resolve(ImageConfiguration.empty));
        expect(requests, 1);
        final moments = await MediaCache.cached('moments', first.cacheKey!,
            accountId: account);
        expect(moments, isNotNull);
        expect(moments!.path, chat.path);
        final objects = await chat.parent
            .list()
            .where((entry) => entry is File && !entry.path.endsWith('.len'))
            .toList();
        expect(objects, hasLength(1));

        final bob = MomentMediaCache.imageProvider(
            '$origin/api/v1/moments/media/content/signed-A',
            cacheKey: reference,
            accountKey: bobPageAccount,
            trustedOrigin: origin);
        await imageReady(bob.resolve(ImageConfiguration.empty));
        final bobMoments = await MediaCache.cached('moments', bob.cacheKey!,
            accountId: bobAccount);
        expect(bobMoments, isNotNull);
        expect(bobMoments!.path, isNot(moments.path));
        expect(requests, 2);

        await first.evict();
        await server.close(force: true);
        final rotated = MomentMediaCache.imageProvider(
            '$origin/api/v1/moments/media/content/signed-B',
            cacheKey: reference,
            accountKey: pageAccount,
            trustedOrigin: origin);
        await imageReady(rotated.resolve(ImageConfiguration.empty));
        expect(requests, 2);
        await MediaCache.clearAccount(account);
        expect(
            await MediaCache.cached('moments', first.cacheKey!,
                accountId: account),
            isNull);
        expect(
            await MediaCache.cached('moments', bob.cacheKey!,
                accountId: bobAccount),
            isNotNull);
      } finally {
        await MediaCache.clearAccount(account);
        await MediaCache.clearAccount(bobAccount);
        await server.close(force: true);
      }
    }, _RealHttp());
  });

  test('offline pre-upgrade Moments cache migrates after aliasing is enabled',
      () async {
    const pageAccount = 'matrix:@legacy:example.test';
    const account = '@legacy:example.test';
    const reference =
        'fefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe';
    final provider = MomentMediaCache.imageProvider(
        'http://127.0.0.1:1/api/v1/moments/media/content/legacy',
        cacheKey: reference,
        accountKey: pageAccount,
        trustedOrigin: 'http://127.0.0.1:1');
    try {
      final baselineKey = _baselineMomentsUrlKey(pageAccount, provider.url);
      await MomentMediaCache.manager
          .putFile(provider.url, png, key: baselineKey, fileExtension: 'png');
      await imageReady(provider.resolve(ImageConfiguration.empty));
      expect(
          await MediaCache.cached('moments', provider.cacheKey!,
              accountId: account),
          isNotNull);
      expect(
          await MomentMediaCache.manager.getFileFromCache(baselineKey), isNull);
    } finally {
      await MediaCache.clearAccount(account);
    }
  });

  test('a clear tombstone discards evicted legacy media and fetches online',
      () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(png);
        await request.response.close();
      });
      const pageAccount = 'matrix:@refresh:example.test';
      const account = '@refresh:example.test';
      const firstReference =
          'cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd';
      try {
        final origin = 'http://127.0.0.1:${server.port}';
        final first = MomentMediaCache.imageProvider(
            '$origin/api/v1/moments/media/content/legacy',
            cacheKey: firstReference,
            accountKey: pageAccount,
            trustedOrigin: origin);
        final baselineKey = _baselineMomentsUrlKey(pageAccount, first.url);
        await MomentMediaCache.manager
            .putFile(first.url, png, key: baselineKey, fileExtension: 'png');
        for (var index = 0;
            index <= MomentMediaCache.maximumDiskEntries;
            index++) {
          final key = index.toRadixString(16).padLeft(64, '0');
          MomentMediaCache.imageProvider(
              '$origin/api/v1/moments/media/content/$index',
              cacheKey: key,
              accountKey: pageAccount,
              trustedOrigin: origin);
        }
        await MediaCache.clearAccount(account);
        final fresh = MomentMediaCache.imageProvider(first.url,
            cacheKey: firstReference,
            accountKey: pageAccount,
            trustedOrigin: origin);
        await imageReady(fresh.resolve(ImageConfiguration.empty));
        expect(requests, 1);
        expect(
            await MediaCache.cached('moments', fresh.cacheKey!,
                accountId: account),
            isNotNull);
        expect(await MomentMediaCache.manager.getFileFromCache(baselineKey),
            isNull);
      } finally {
        await MediaCache.clearAccount(account);
        await server.close(force: true);
      }
    }, _RealHttp());
  });

  test('a clear tombstone rejects an evicted pre-upgrade Moments cache',
      () async {
    const pageAccount = 'matrix:@revoked:example.test';
    const account = '@revoked:example.test';
    const firstReference =
        'abababababababababababababababababababababababababababababababab';
    const origin = 'http://127.0.0.1:1';
    final first = MomentMediaCache.imageProvider(
        '$origin/api/v1/moments/media/content/legacy',
        cacheKey: firstReference,
        accountKey: pageAccount,
        trustedOrigin: origin);
    try {
      final baselineKey = _baselineMomentsUrlKey(pageAccount, first.url);
      await MomentMediaCache.manager
          .putFile(first.url, png, key: baselineKey, fileExtension: 'png');
      for (var index = 0;
          index <= MomentMediaCache.maximumDiskEntries;
          index++) {
        final key = index.toRadixString(16).padLeft(64, '0');
        MomentMediaCache.imageProvider(
            '$origin/api/v1/moments/media/content/$index',
            cacheKey: key,
            accountKey: pageAccount,
            trustedOrigin: origin);
      }
      await MediaCache.clearAccount(account);
      final fresh = MomentMediaCache.imageProvider(first.url,
          cacheKey: firstReference,
          accountKey: pageAccount,
          trustedOrigin: origin);
      await expectLater(imageReady(fresh.resolve(ImageConfiguration.empty)),
          throwsA(anything));
      expect(
          await MediaCache.cached('moments', fresh.cacheKey!,
              accountId: account),
          isNull);
    } finally {
      await MediaCache.clearAccount(account);
    }
  });

  test('trusted avatar content remains on the normal cache-manager path',
      () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(png);
        await request.response.close();
      });
      try {
        final origin = 'http://127.0.0.1:${server.port}';
        final provider = MomentMediaCache.imageProvider(
            '$origin/api/v1/profile/avatar/content/avatar',
            cacheKey:
                'edededededededededededededededededededededededededededededededed',
            accountKey: 'matrix:@avatar:example.test',
            trustedOrigin: origin);
        await imageReady(provider.resolve(ImageConfiguration.empty));
        expect(requests, 1);
      } finally {
        await server.close(force: true);
      }
    }, _RealHttp());
  });

  test('clearing an account revokes a held Moments download before it stores',
      () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requested = Completer<void>();
      final release = Completer<void>();
      var requests = 0;
      server.listen((request) async {
        requests++;
        if (!requested.isCompleted) requested.complete();
        await release.future;
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(png);
        await request.response.close();
      });
      const pageAccount = 'matrix:@held:example.test';
      const account = '@held:example.test';
      const reference =
          'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
      try {
        final provider = MomentMediaCache.imageProvider(
            'http://127.0.0.1:${server.port}/api/v1/moments/media/content/held',
            cacheKey: reference,
            accountKey: pageAccount,
            trustedOrigin: 'http://127.0.0.1:${server.port}');
        final pending = MomentMediaCache.manager
            .getFileStream(provider.url, key: provider.cacheKey)
            .where((response) => response is FileInfo)
            .cast<FileInfo>()
            .first;
        await requested.future;
        await MediaCache.clearAccount(account);
        release.complete();
        await expectLater(pending, throwsStateError);
        expect(
            await MediaCache.cached('moments', provider.cacheKey!,
                accountId: account),
            isNull);
        final fresh = MomentMediaCache.imageProvider(provider.url,
            cacheKey: reference,
            accountKey: pageAccount,
            trustedOrigin: 'http://127.0.0.1:${server.port}');
        await imageReady(fresh.resolve(ImageConfiguration.empty));
        expect(requests, 2);
        expect(
            await MediaCache.cached('moments', fresh.cacheKey!,
                accountId: account),
            isNotNull);
      } finally {
        if (!release.isCompleted) release.complete();
        await MediaCache.clearAccount(account);
        await server.close(force: true);
      }
    }, _RealHttp());
  });

  testWidgets(
      'account switch resets image state while signed rotation retains it',
      (tester) async {
    Future<Key?> render(String account, String signedPath) async {
      await tester.pumpWidget(CupertinoApp(
          home: WeChatMomentImageGrid(
        imageUrls: [
          'https://media.test/api/v1/profile/avatar/content/$signedPath'
        ],
        imageCacheKeys: const [
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        ],
        mediaAccountKey: account,
        mediaOrigin: 'https://media.test',
      )));
      return tester.widget<Image>(find.byType(Image)).key;
    }

    final first = await render('alice', 'signed-A');
    expect(await render('alice', 'signed-B'), first);
    expect(await render('bob', 'signed-B'), isNot(first));
  });

  test(
      'video poster uses shared account cache across renewed draft URLs and clears',
      () async {
    const origin = 'https://media.example';
    const first = '$origin/api/v1/moments/media/content/old';
    const renewed = '$origin/api/v1/moments/media/content/new';
    const account = '@poster:example';
    const other = '@other-poster:example';
    final key = 'a' * 64;
    final generation = MediaCache.accountGeneration(account);
    await MomentMediaCache.storeVideoPoster(first, png,
        cacheKey: key,
        accountKey: account,
        trustedOrigin: origin,
        expectedAccountGeneration: generation);
    expect(
        await MomentMediaCache.cachedVideoPoster(renewed,
            cacheKey: key, accountKey: account, trustedOrigin: origin),
        png);
    expect(
        await MomentMediaCache.cachedVideoPoster(renewed,
            cacheKey: key, accountKey: other, trustedOrigin: origin),
        isNull);
    expect(
        await MomentMediaCache.cachedVideoPoster(renewed,
            cacheKey: 'b' * 64, accountKey: account, trustedOrigin: origin),
        isNull);
    await MomentMediaCache.removeVideoPoster(renewed,
        cacheKey: key, accountKey: account, trustedOrigin: origin);
    expect(
        await MomentMediaCache.cachedVideoPoster(first,
            cacheKey: key, accountKey: account, trustedOrigin: origin),
        isNull);
    await MomentMediaCache.storeVideoPoster(first, png,
        cacheKey: key,
        accountKey: account,
        trustedOrigin: origin,
        expectedAccountGeneration: generation);
    await MediaCache.clearAccount(account);
    expect(
        await MomentMediaCache.cachedVideoPoster(renewed,
            cacheKey: key, accountKey: account, trustedOrigin: origin),
        isNull);
    await expectLater(
        MomentMediaCache.storeVideoPoster(first, png,
            cacheKey: key,
            accountKey: account,
            trustedOrigin: origin,
            expectedAccountGeneration: generation),
        throwsStateError);
    await expectLater(
        MomentMediaCache.storeVideoPoster(
            'https://foreign.example/api/v1/moments/media/content/a', png,
            cacheKey: key,
            accountKey: account,
            trustedOrigin: origin,
            expectedAccountGeneration: MediaCache.accountGeneration(account)),
        throwsStateError);
    await MediaCache.clearAccount(other);
  });

  testWidgets('cached original GIF keeps multiple frames in feed thumbnail',
      (tester) async {
    const url = 'https://example.invalid/animated.gif';
    final gif = base64Decode(
        'R0lGODlhAgACAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAgACAAAIBgABCAQQEAAh+QQBCgABACwAAAAAAgACAIEAAP8AAAAAAAAAAAAIBgABCAQQEAA7');
    await tester.runAsync(() async {
      await MomentMediaCache.manager.putFile(url, gif, fileExtension: 'gif');
    });
    final frames = <ui.Image>[];
    late ImageStream stream;
    final firstFrame = Completer<void>();
    final listener = ImageStreamListener((info, _) {
      frames.add(info.image.clone());
      if (!firstFrame.isCompleted) firstFrame.complete();
    });
    await tester.runAsync(() async {
      stream = MomentThumbnailProvider(MomentMediaCache.imageProvider(url),
              extent: 540)
          .resolve(ImageConfiguration.empty);
      stream.addListener(listener);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    try {
      for (var i = 0; i < 20 && frames.length < 2; i++) {
        await tester.pump(const Duration(milliseconds: 150));
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
      }
      expect(frames.length, greaterThanOrEqualTo(2));
      final first = await tester.runAsync(() => frames[0].toByteData());
      final second = await tester.runAsync(() => frames[1].toByteData());
      expect(first!.buffer.asUint8List(), isNot(second!.buffer.asUint8List()));
    } finally {
      stream.removeListener(listener);
      for (final frame in frames) {
        frame.dispose();
      }
    }
  });

  testWidgets('Moments thumbnails use a disk-backed image provider',
      (tester) async {
    await tester.pumpWidget(const CupertinoApp(
        home: WeChatMomentImageGrid(
      imageUrls: ['https://example.invalid/moment.png'],
    )));
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<MomentThumbnailProvider>());
    final thumbnail = image.image as MomentThumbnailProvider;
    expect(thumbnail.extent, 540);
    expect(
        thumbnail.imageProvider.cacheManager, same(MomentMediaCache.manager));
  });

  testWidgets('memory hit paints immediately in grid and viewer without fade',
      (tester) async {
    const url = 'https://example.invalid/preloaded.png';
    await tester.runAsync(() async {
      await MomentMediaCache.manager.putFile(url, png, fileExtension: 'png');
      final provider = MomentMediaCache.imageProvider(url);
      final stream = provider.resolve(ImageConfiguration.empty);
      await imageReady(stream);
      await imageReady(MomentThumbnailProvider(provider, extent: 540)
          .resolve(ImageConfiguration.empty));
    });
    await tester.pumpWidget(
        const CupertinoApp(home: WeChatMomentImageGrid(imageUrls: [url])));
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(find.byType(FadeTransition), findsNothing);
    await tester.pumpWidget(const CupertinoApp(
        home: MomentImageViewerPage(imageUrls: [url], initialIndex: 0)));
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.pumpWidget(CupertinoApp(
        home: WeChatMomentCoverViewer(
            url: url, onChangeCover: (_) async => null)));
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
  });

  testWidgets('grid decode follows DPR with a bounded aspect-preserving size',
      (tester) async {
    for (final sample in [(1, 1.5, 270), (2, 2.5, 225), (1, 8.0, 1024)]) {
      tester.view.devicePixelRatio = sample.$2;
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(CupertinoApp(
          home: WeChatMomentImageGrid(
              imageUrls: List.generate(sample.$1,
                  (index) => 'https://example.invalid/sized-$index.png'))));
      final provider = tester.widgetList<Image>(find.byType(Image)).first.image;
      expect(provider, isA<MomentThumbnailProvider>());
      final thumbnail = provider as MomentThumbnailProvider;
      expect(thumbnail.extent, sample.$3);
    }
  });

  for (final sample in [
    (1200, 600, 1080, 540),
    (600, 1200, 540, 1080),
    (12000, 100, 4096, 34),
    (4096, 1024, 2048, 512),
    (100, 50, 100, 50),
  ]) {
    testWidgets('cover decode $sample keeps ratio and retry clears both keys',
        (tester) async {
      final url = 'https://example.invalid/cover-${sample.$1}-${sample.$2}.png';
      final original = MomentMediaCache.imageProvider(url);
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder)
            .drawPaint(ui.Paint()..color = const Color(0xff112233));
        final picture = recorder.endRecording();
        final large = picture.toImageSync(sample.$1, sample.$2);
        final bytes = await large
            .toByteData(format: ui.ImageByteFormat.png)
            .timeout(const Duration(seconds: 10));
        await MomentMediaCache.manager
            .putFile(url, bytes!.buffer.asUint8List(), fileExtension: 'png');
        large.dispose();
        picture.dispose();
        await imageReady(original.resolve(ImageConfiguration.empty))
            .timeout(const Duration(seconds: 10));
        await imageReady(MomentThumbnailProvider(original, extent: 540)
            .resolve(ImageConfiguration.empty));
      });
      await tester.pumpWidget(
          CupertinoApp(home: WeChatMomentImageGrid(imageUrls: [url])));
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<MomentThumbnailProvider>());
      final thumbnail = image.image as MomentThumbnailProvider;
      final decoded = tester.widget<RawImage>(find.byType(RawImage)).image!;
      expect(decoded.width, sample.$3);
      expect(decoded.height, sample.$4);
      expect(decoded.width * decoded.height, lessThanOrEqualTo(1024 * 1024));
      await tester.runAsync(() async {
        final thumbnailKey =
            await thumbnail.obtainKey(ImageConfiguration.empty);
        final cache = PaintingBinding.instance.imageCache;
        expect(cache.containsKey(original), isTrue);
        expect(cache.containsKey(thumbnailKey), isTrue);
        final error = image.errorBuilder!(
                tester.element(find.byType(Image)), StateError('corrupt'), null)
            as ColoredBox;
        final retry = error.child! as CupertinoButton;
        // The error action is asynchronous, so wait for its explicit work rather
        // than running fake test-clock timers for the disk cache.
        await (retry.onPressed! as Future<void> Function())()
            .timeout(const Duration(seconds: 10));
        expect(cache.containsKey(original), isFalse);
        expect(cache.containsKey(thumbnailKey), isFalse);
        expect(await MomentMediaCache.manager.getFileFromCache(url), isNull);
      });
    });
  }

  test('thumbnail identity includes account, signed content and decode extent',
      () {
    const origin = 'https://media.example.test';
    const digest =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    MomentThumbnailProvider provider(String account, String path, int extent) =>
        MomentThumbnailProvider(
            MomentMediaCache.imageProvider(
                '$origin/api/v1/profile/avatar/content/$path',
                cacheKey: digest,
                accountKey: account,
                trustedOrigin: origin),
            extent: extent);
    final first = provider('alice', 'signed-A', 540);
    final rotated = provider('alice', 'signed-B', 540);
    expect(first, rotated);
    expect(first.hashCode, rotated.hashCode);
    expect(first, isNot(provider('bob', 'signed-A', 540)));
    expect(first, isNot(provider('alice', 'signed-A', 270)));
    var synchronous = false;
    first.obtainKey(ImageConfiguration.empty).then((_) => synchronous = true);
    expect(synchronous, isTrue);
  });

  test('failed decode evicts thumbnail key as well as the delegated key',
      () async {
    const url = 'https://example.invalid/corrupt-thumbnail.png';
    final original = MomentMediaCache.imageProvider(url);
    final thumbnail = MomentThumbnailProvider(original, extent: 540);
    await MomentMediaCache.manager
        .putFile(url, base64Decode('AAAA'), fileExtension: 'png');
    await expectLater(imageReady(thumbnail.resolve(ImageConfiguration.empty)),
        throwsA(anything));
    await Future<void>.delayed(Duration.zero);
    final cache = PaintingBinding.instance.imageCache;
    expect(cache.containsKey(thumbnail), isFalse);
    expect(cache.statusForKey(thumbnail).live, isFalse);
  });
}

Future<void> imageReady(ImageStream stream) async {
  final completer = Completer<void>();
  late ImageStreamListener listener;
  listener = ImageStreamListener((info, synchronous) {
    info.dispose();
    completer.complete();
  }, onError: completer.completeError);
  stream.addListener(listener);
  try {
    await completer.future;
  } finally {
    stream.removeListener(listener);
  }
}

String _baselineMomentsUrlKey(String accountKey, String url) =>
    'moments-url-account-v1:${sha256.convert(utf8.encode(jsonEncode([
          accountKey,
          url
        ])))}';
