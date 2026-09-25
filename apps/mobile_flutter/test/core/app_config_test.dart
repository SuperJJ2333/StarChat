import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/app_config.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/profile/about_page.dart';
import 'package:liuhetong_mobile/features/update/app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';

final class _Memory implements SecureKeyValueStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}

void main() {
  Future<int> loadAndroidBuild(int installedBuild) async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      PackageInfo.setMockInitialValues(
        appName: 'ChatFlow',
        packageName: 'com.liuhetong.mobile',
        version: '0.4.13',
        buildNumber: '$installedBuild',
        buildSignature: '',
      );
      await AppConfig.loadRuntimeVersion();
      return AppConfig.appBuildNumber;
    } finally {
      debugDefaultTargetPlatformOverride = previousPlatform;
    }
  }

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    AppConfig.appVersionName = '0.4.13';
    AppConfig.appBuildNumber = AppConfig.compiledBuildNumber;
  });

  test('release defaults point to the production HTTPS endpoints', () {
    expect(AppConfig.businessApiBaseUrl, 'https://liuhetong888.com');
    expect(AppConfig.matrixHomeserver, 'https://liuhetong888.com');
  });

  test('runtime version falls back to the pubspec-synced defaults off-device',
      () async {
    // 平台通道不可用时（如测试环境）保留默认值，不抛错。
    await AppConfig.loadRuntimeVersion();
    expect(AppConfig.appVersionName, isNotEmpty);
    expect(AppConfig.appBuildNumber, 2179);
  });

  test('Android non-split four-digit build remains intact at runtime',
      () async {
    expect(await loadAndroidBuild(2179), 2179);
  });

  test('Android known ABI split offsets map to the compiled build', () async {
    for (final offset in [1000, 2000, 4000]) {
      expect(await loadAndroidBuild(2179 + offset), 2179,
          reason: 'ABI offset $offset');
    }
  });

  test('Android unrelated four-digit code remains intact', () async {
    expect(await loadAndroidBuild(3197), 3197);
  });

  testWidgets('About detail displays the full Android build', (tester) async {
    await loadAndroidBuild(2179);
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: SecureSessionStore(_Memory()),
      client: MockClient((_) async => http.Response('{}', 200)),
    );
    await tester.pumpWidget(CupertinoApp(home: AboutDetailPage(api: api)));
    expect(find.text('V0.4.13 (Build 2179)'), findsOneWidget);
  });

  test('full Android build does not trigger a false forced update', () async {
    final build = await loadAndroidBuild(2179);
    const info = AppUpdateInfo(
      latestVersion: '0.4.13',
      latestBuild: 2179,
      minSupportedBuild: 2179,
      notes: '',
      apkUrl: '',
    );
    expect(requiresForcedUpdate(info, build), isFalse);
  });

  test('build number normalization strips only known ABI offsets', () {
    expect(AppConfig.normalizeBuildNumber(6179), 2179, reason: 'x86_64 包');
    expect(AppConfig.normalizeBuildNumber(4179), 2179, reason: 'arm64 包');
    expect(AppConfig.normalizeBuildNumber(3179), 2179, reason: 'arm32 包');
    expect(AppConfig.normalizeBuildNumber(2179), 2179, reason: '普通四位包');
    expect(AppConfig.normalizeBuildNumber(3197), 3197, reason: '未知四位包');
    expect(AppConfig.normalizeBuildNumber(20), 20, reason: '旧三位内构建号');
    expect(AppConfig.normalizeBuildNumber(6), 6);
  });
}
