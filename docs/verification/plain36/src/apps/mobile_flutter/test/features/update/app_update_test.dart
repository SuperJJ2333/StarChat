import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/update/app_update.dart';

final class FakeUpdateGateway implements AppUpdateGateway {
  FakeUpdateGateway(this.payload);
  Map<String, dynamic> payload;
  int calls = 0;

  @override
  Future<Map<String, dynamic>> latestAppUpdate() async {
    calls++;
    return payload;
  }
}

Map<String, dynamic> get publishedPayload => {
      'configured': true,
      'latest_version': '0.4.0',
      'latest_build': 4,
      'min_supported_build': 2,
      'notes': '修复已知问题，新增版本更新提醒。',
      'apk_url': 'https://www.liuhetong888.com/downloads/app-release.apk',
    };

void main() {
  test('unconfigured payloads parse to null', () {
    expect(
      parseAppUpdate({
        'configured': false,
        'latest_version': null,
        'latest_build': null,
        'min_supported_build': null,
        'notes': null,
        'apk_url': null,
      }),
      isNull,
    );
  });

  test('published payloads parse into structured info', () {
    final info = parseAppUpdate(publishedPayload);
    expect(info, isNotNull);
    expect(info!.latestVersion, '0.4.0');
    expect(info.latestBuild, 4);
    expect(info.minSupportedBuild, 2);
    expect(info.apkUrl, contains('/downloads/app-release.apk'));
  });

  test('current builds at or above latest need no update', () {
    final info = parseAppUpdate(publishedPayload);
    expect(resolvePendingUpdate(info: info, currentBuild: 4), isNull);
    expect(resolvePendingUpdate(info: info, currentBuild: 5), isNull);
  });

  test('older builds get a pending update with forced flag', () {
    final info = parseAppUpdate(publishedPayload);
    final pending = resolvePendingUpdate(info: info, currentBuild: 3);
    expect(pending, isNotNull);
    expect(requiresForcedUpdate(pending!, 3), isFalse);

    final forced = resolvePendingUpdate(info: info, currentBuild: 1);
    expect(forced, isNotNull);
    expect(requiresForcedUpdate(forced!, 1), isTrue);
  });

  test('gateway is queried through the business API only', () async {
    final gateway = FakeUpdateGateway(publishedPayload);
    final info = parseAppUpdate(await gateway.latestAppUpdate());
    expect(resolvePendingUpdate(info: info, currentBuild: 1), isNotNull);
    expect(gateway.calls, 1);
  });

  test('semantic version compare works despite abi-offset build numbers',
      () {
    // 服务端发布策略：latest_build 使用 arm64 清单值（2000+build）。
    // 旧版构建号比较在新客户端上失真，语义化版本名比较必须兜住：
    final info = parseAppUpdate({
      ...publishedPayload,
      'latest_version': '0.3.20',
      'latest_build': 2023,
    });
    // 0.3.19 客户端（归一化 build=22 < 2023）→ 提示更新（本身也确实过期）。
    expect(
      resolvePendingUpdate(
          info: info, currentBuild: 22, currentVersion: '0.3.19'),
      isNotNull,
    );
    // 0.3.20 客户端：构建号 23 < 2023 会误报，语义比较必须判定为最新。
    expect(
      resolvePendingUpdate(
          info: info, currentBuild: 23, currentVersion: '0.3.20'),
      isNull,
      reason: '同版本不能因 abi 偏移构建号误弹更新窗',
    );
    // 更高版本客户端：安静。
    expect(
      resolvePendingUpdate(
          info: info, currentBuild: 24, currentVersion: '0.3.21'),
      isNull,
    );
  });

  test('semantic compare falls back to build numbers when unparsable', () {
    final info = parseAppUpdate({
      ...publishedPayload,
      'latest_version': 'not-a-version',
    });
    expect(
      resolvePendingUpdate(info: info, currentBuild: 3, currentVersion: '0.3.19'),
      isNotNull,
      reason: '版本名不可解析时回退构建号比较',
    );
    expect(
      resolvePendingUpdate(info: info, currentBuild: 99, currentVersion: 'x'),
      isNull,
    );
  });

  test('version names compare segment-wise with missing parts as zero', () {
    expect(compareVersions('0.3.20', '0.3.20'), 0);
    expect(compareVersions('0.3.20', '0.3.19'), 1);
    expect(compareVersions('0.3.19', '0.3.20'), -1);
    expect(compareVersions('0.4', '0.3.9'), 1, reason: '缺失段按 0 补齐');
    expect(compareVersions('1.0', '0.9.9'), 1);
    expect(compareVersions('0.3.20', ''), isNull);
    expect(compareVersions('', '0.3.20'), isNull);
    expect(compareVersions('abc', '0.3.20'), isNull);
  });
}
