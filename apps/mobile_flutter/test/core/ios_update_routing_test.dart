import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/app_config.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:package_info_plus/package_info_plus.dart';

class _Memory implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);
  test('iOS runtime build keeps its full monotonic number', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final previousName = AppConfig.appVersionName;
    final previousBuild = AppConfig.appBuildNumber;
    addTearDown(() {
      AppConfig.appVersionName = previousName;
      AppConfig.appBuildNumber = previousBuild;
    });
    PackageInfo.setMockInitialValues(
        appName: 'ChatFlow',
        packageName: 'example',
        version: '0.3.70',
        buildNumber: '2074',
        buildSignature: '');
    await AppConfig.loadRuntimeVersion();
    expect(AppConfig.appBuildNumber, 2074);
  });
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test('$platform update uses its own release channel', () async {
      debugDefaultTargetPlatformOverride = platform;
      final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: SecureSessionStore(_Memory()),
        client: MockClient((request) async {
          expect(request.url.path, '/api/v1/app-updates/latest');
          expect(request.url.queryParameters,
              platform == TargetPlatform.iOS ? {'platform': 'ios'} : isEmpty);
          return http.Response(
              jsonEncode({
                'configured': true,
                if (platform == TargetPlatform.iOS) 'platform': 'ios',
                'latest_version': '0.3.69',
                'latest_build': 2074,
                'apk_url': platform == TargetPlatform.iOS
                    ? 'https://www.example.com/download'
                    : 'https://www.example.com/app.apk',
              }),
              200);
        }),
      );
      expect((await api.latestAppUpdate())['configured'], true);
    });
  }
  test('iOS ignores legacy server Android release projection', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: SecureSessionStore(_Memory()),
      client: MockClient((_) async => http.Response(
          jsonEncode({
            'configured': true,
            'latest_version': '0.3.68',
            'latest_build': 2072,
            'apk_url': 'https://www.example.com/android.apk',
          }),
          200)),
    );
    expect((await api.latestAppUpdate())['configured'], false);
  });
}
