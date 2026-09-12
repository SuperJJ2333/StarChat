import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:liuhetong_mobile/ui/moments/moment_media_cache.dart';
import 'package:liuhetong_mobile/ui/moments/moment_image_viewer_page.dart';
import 'package:liuhetong_mobile/ui/moments/wechat_moment_image_grid.dart';
import 'package:liuhetong_mobile/ui/moments/wechat_moment_viewer.dart';
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
  final scratch = Directory(
          '../../docs/verification/artifacts/2026-09-10/four-fixes-2083/media/cache-${DateTime.now().microsecondsSinceEpoch}')
      .absolute;
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

  testWidgets('Moments thumbnails use a disk-backed image provider',
      (tester) async {
    await tester.pumpWidget(const CupertinoApp(
        home: WeChatMomentImageGrid(
      imageUrls: ['https://example.invalid/moment.png'],
    )));
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<CachedNetworkImageProvider>());
    expect((image.image as CachedNetworkImageProvider).cacheManager,
        same(MomentMediaCache.manager));
  });

  testWidgets('memory hit paints immediately in grid and viewer without fade',
      (tester) async {
    const url = 'https://example.invalid/preloaded.png';
    await tester.runAsync(() async {
      await MomentMediaCache.manager.putFile(url, png, fileExtension: 'png');
      final provider = MomentMediaCache.imageProvider(url);
      final stream = provider.resolve(ImageConfiguration.empty);
      await imageReady(stream);
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
}

Future<void> imageReady(ImageStream stream) async {
  final completer = Completer<void>();
  late ImageStreamListener listener;
  listener = ImageStreamListener((info, synchronous) {
    info.dispose();
    completer.complete();
  }, onError: completer.completeError);
  stream.addListener(listener);
  await completer.future;
  stream.removeListener(listener);
}

String _baselineMomentsUrlKey(String accountKey, String url) =>
    'moments-url-account-v1:${sha256.convert(utf8.encode(jsonEncode([
          accountKey,
          url
        ])))}';
