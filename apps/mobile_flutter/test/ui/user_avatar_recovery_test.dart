import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/components/user_avatar.dart';
import 'package:liuhetong_mobile/ui/foundation/avatar_cache.dart';
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
  final originalPaths = PathProviderPlatform.instance;
  final originalHttp = HttpOverrides.current;
  setUpAll(() async {
    final root = Directory(
            '../../docs/verification/artifacts/2026-09-11/performance/avatar-http-${DateTime.now().microsecondsSinceEpoch}')
        .absolute;
    await root.create(recursive: true);
    PathProviderPlatform.instance = _Paths(root.path);
    HttpOverrides.global = _RealHttp();
  });
  tearDownAll(() async {
    await AvatarCache.manager.dispose();
    PathProviderPlatform.instance = originalPaths;
    HttpOverrides.global = originalHttp;
  });
  testWidgets(
      'real avatar HTTP and decode failures recover with unchanged props',
      (tester) async {
    for (final corrupt in [true, false]) {
      final png = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');
      var healthy = false;
      var requests = 0;
      final server = (await tester
          .runAsync(() => HttpServer.bind(InternetAddress.loopbackIPv4, 0)))!;
      server.listen((request) async {
        requests++;
        request.response.statusCode = healthy || corrupt ? 200 : 503;
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(healthy ? png : utf8.encode('invalid-image'));
        await request.response.close();
      });
      final url = 'http://127.0.0.1:${server.port}/avatar';
      await tester.pumpWidget(CupertinoApp(
          home: Column(children: [
        for (var i = 0; i < 2; i++)
          UserAvatar(
              nickname: 'Alice',
              fallbackSeed: 'recovery:$corrupt',
              avatarUrl: url),
      ])));
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
        if (requests > 0 && find.text('A').evaluate().isNotEmpty) break;
      }
      expect(requests, 1);
      expect(find.text('A'), findsNWidgets(2));
      healthy = true;
      await tester.pump(const Duration(seconds: 1));
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
        if (tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((image) => image.image != null)) {
          break;
        }
      }
      final painted = tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((image) => image.image != null);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => server.close(force: true));
      expect(painted, isTrue);
      expect(requests, 2);
    }
    await tester.pump(const Duration(seconds: 20));
  });
}
