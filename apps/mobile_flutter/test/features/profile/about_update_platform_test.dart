import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/profile/about_page.dart';

final class _Memory implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform About update opens its own download destination',
        (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      final os = platform == TargetPlatform.iOS ? 'ios' : 'android';
      final destination = 'https://download.example.com/$os/release';
      final launches = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'launch') {
          launches.add((call.arguments as Map)['url'] as String);
        }
        return true;
      });
      final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: SecureSessionStore(_Memory()),
        client: MockClient((request) async {
          expect(request.url.path, '/api/v1/app-updates/latest');
          expect(request.url.queryParameters, {'platform': os});
          return http.Response(
              jsonEncode({
                'platform': os,
                'configured': true,
                'latest_version': '99.0.0',
                'latest_build': 9900,
                'min_supported_build': 0,
                'notes': '$os release',
                'download_url': destination,
                'apk_url': 'https://download.example.com/legacy',
              }),
              200);
        }),
      );
      await tester.pumpWidget(CupertinoApp(home: AboutDetailPage(api: api)));
      await tester.tap(find.byKey(const Key('about-check-update-row')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('发现新版本 99.0.0'), findsOneWidget);
      await tester.tap(find.byKey(const Key('app-update-now')));
      await tester.pump();
      expect(launches, [destination]);
      await tester.tap(find.byKey(const Key('app-update-defer')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
      await tester.tap(find.byKey(const Key('about-check-update-row')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('发现新版本 99.0.0'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
