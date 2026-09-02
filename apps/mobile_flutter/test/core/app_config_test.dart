import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/app_config.dart';

void main() {
  test('release defaults point to the production HTTPS endpoints', () {
    expect(AppConfig.businessApiBaseUrl, 'https://liuhetong888.com');
    expect(AppConfig.matrixHomeserver, 'https://liuhetong888.com');
  });

  test('runtime version falls back to the pubspec-synced defaults off-device',
      () async {
    // 平台通道不可用时（如测试环境）保留默认值，不抛错。
    await AppConfig.loadRuntimeVersion();
    expect(AppConfig.appVersionName, isNotEmpty);
    expect(AppConfig.appBuildNumber, greaterThan(0));
  });

  test('build number normalization strips the Android split-abi offset', () {
    expect(AppConfig.normalizeBuildNumber(4020), 20, reason: 'x86_64 包');
    expect(AppConfig.normalizeBuildNumber(2020), 20, reason: 'arm64 包');
    expect(AppConfig.normalizeBuildNumber(1013), 13, reason: 'arm32 包');
    expect(AppConfig.normalizeBuildNumber(20), 20, reason: 'iOS/未分包原值');
    expect(AppConfig.normalizeBuildNumber(6), 6);
  });
}
