import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
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
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final oldPaths = PathProviderPlatform.instance;
  final scratch = Directory(
          '../../docs/verification/artifacts/2026-09-09/mobile-parity/media-cache-${DateTime.now().microsecondsSinceEpoch}')
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

  test('repeat reads reuse disk after decoded image eviction', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.headers.set('cache-control', 'max-age=3600');
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(png);
        await request.response.close();
      });
      try {
        final url = 'http://127.0.0.1:${server.port}/moment.png';
        final first = await MomentMediaCache.manager.getSingleFile(url);
        expect(await first.readAsBytes(), png);
        await imageReady(MomentMediaCache.imageProvider(url)
            .resolve(ImageConfiguration.empty));
        await MomentMediaCache.imageProvider(url).evict();
        await imageReady(MomentMediaCache.imageProvider(url)
            .resolve(ImageConfiguration.empty));
        final second = await MomentMediaCache.manager.getSingleFile(url);
        expect(second.path, first.path);
        expect(await second.readAsBytes(), png);
        expect(requests, 1);
      } finally {
        await server.close(force: true);
      }
    }, _RealHttp());
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
