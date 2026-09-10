import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/moments/moment_media_cache.dart';
import 'package:liuhetong_mobile/ui/moments/moment_image_viewer_page.dart';
import 'package:liuhetong_mobile/ui/moments/wechat_moment_image_grid.dart';
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
  final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');
  final oldPaths = PathProviderPlatform.instance;
  setUpAll(() async {
    final root = Directory(
            '../../docs/verification/artifacts/2026-09-10/four-fixes-2083/media/http-${DateTime.now().microsecondsSinceEpoch}')
        .absolute;
    await root.create(recursive: true);
    PathProviderPlatform.instance = _Paths(root.path);
  });
  tearDownAll(() async {
    await MomentMediaCache.manager.dispose();
    PathProviderPlatform.instance = oldPaths;
  });

  test('URL fallback is isolated by account and keeps complete URL identity',
      () {
    const url = 'https://example.test/image?signature=A';
    final alice = MomentMediaCache.imageProvider(url, accountKey: 'alice');
    final bob = MomentMediaCache.imageProvider(url, accountKey: 'bob');
    expect(alice, isNot(bob));
    expect(alice.cacheKey, isNot(bob.cacheKey));
    expect(alice,
        isNot(MomentMediaCache.imageProvider('$url&v=2', accountKey: 'alice')));
  });

  test(
      'real HTTP disk revisit, TTL refresh, offline preservation, retry and bounded downloads',
      () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      var active = 0;
      var peak = 0;
      var fail = false;
      server.listen((request) async {
        requests++;
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(const Duration(milliseconds: 40));
        request.response.statusCode = fail ? 503 : 200;
        request.response.headers.set('cache-control', 'max-age=3600');
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(png);
        active--;
        await request.response.close();
      });
      try {
        final url = 'http://127.0.0.1:${server.port}/image';
        final manager = MomentMediaCache.manager;
        await manager.getFileStream(url).toList();
        expect(requests, 1);
        await manager.getFileStream(url).toList();
        expect(requests, 1, reason: 'successful disk revisit performs no HTTP');
        await manager.putFile(url, png, maxAge: const Duration(seconds: -1));
        await manager.getFileStream(url).toList();
        expect(requests, 2, reason: 'expired data revalidates');
        await manager.putFile(url, png, maxAge: const Duration(seconds: -1));
        fail = true;
        final offline = await manager.getFileStream(url).toList();
        expect(offline.whereType<FileInfo>(), hasLength(1));
        expect(requests, 3);
        await expectLater(
            manager.getFileStream('$url/cold'), emitsError(anything));
        fail = false;
        await manager.getFileStream('$url/cold').toList();
        expect(requests, 5, reason: 'cold failures can retry');
        await Future.wait(List.generate(
            12, (i) => manager.getFileStream('$url/batch/$i').toList()));
        expect(peak, lessThanOrEqualTo(3));
        expect(requests, 17);
      } finally {
        await server.close(force: true);
      }
    }, _RealHttp());
  });

  for (final viewer in [false, true]) {
    testWidgets(
        'failed image viewer=$viewer has an accessible retry and stable bounds',
        (tester) async {
      final semantics = tester.ensureSemantics();
      var requests = 0;
      final server = await tester
          .runAsync(() => HttpServer.bind(InternetAddress.loopbackIPv4, 0));
      server!.listen((request) async {
        requests++;
        request.response.persistentConnection = false;
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(png);
        await request.response.close();
      });
      final url = 'http://127.0.0.1:${server.port}/retry.png';
      await tester.runAsync(() =>
          MomentMediaCache.manager.putFile(url, base64Decode('aW52YWxpZA==')));
      await tester.pumpWidget(CupertinoApp(
          home: viewer
              ? MomentImageViewerPage(imageUrls: [url], initialIndex: 0)
              : Center(child: WeChatMomentImageGrid(imageUrls: [url]))));
      final bounds = viewer
          ? find.byType(InteractiveViewer)
          : find.byKey(const ValueKey('moment-image'));
      final before = tester.getSize(bounds);
      for (var i = 0;
          i < 20 &&
              find.byIcon(CupertinoIcons.arrow_clockwise).evaluate().isEmpty;
          i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pumpAndSettle();
      }
      expect(find.bySemanticsLabel('重新加载图片'), findsOneWidget);
      expect(tester.getSize(bounds), before);
      await tester.tap(find.bySemanticsLabel('重新加载图片'));
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
        if (requests == 1 &&
            tester
                .widgetList<RawImage>(find.byType(RawImage))
                .any((image) => image.image != null)) {
          break;
        }
      }
      expect(requests, 1, reason: 'retry must recover a corrupt disk entry');
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      expect(tester.getSize(bounds), before);
      semantics.dispose();
      await tester.runAsync(() => server.close(force: true));
      await tester.pump(const Duration(seconds: 16));
    });
  }
}
