import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/update/app_update.dart';
import 'package:liuhetong_mobile/features/update/update_integrity.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('UpdateDataIntegrity', () {
    test('first run records the build without producing a report', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      final report = await UpdateDataIntegrity.verify(
        currentBuild: 3,
        checks: [UpdateIntegrityCheck('preferences', () async => true)],
        preferences: prefs,
      );

      expect(report, isNull);
      expect(prefs.getInt(UpdateDataIntegrity.previousBuildKey), 3);
    });

    test('same build on next launch stays silent', () async {
      SharedPreferences.setMockInitialValues(
          {UpdateDataIntegrity.previousBuildKey: 3});
      final prefs = await SharedPreferences.getInstance();
      var probes = 0;

      final report = await UpdateDataIntegrity.verify(
        currentBuild: 3,
        checks: [
          UpdateIntegrityCheck('preferences', () async {
            probes++;
            return true;
          }),
        ],
        preferences: prefs,
      );

      expect(report, isNull);
      expect(probes, 0);
    });

    test('version change runs every probe and reports failures honestly',
        () async {
      SharedPreferences.setMockInitialValues(
          {UpdateDataIntegrity.previousBuildKey: 3});
      final prefs = await SharedPreferences.getInstance();

      final report = await UpdateDataIntegrity.verify(
        currentBuild: 4,
        checks: [
          UpdateIntegrityCheck('preferences', () async => true),
          UpdateIntegrityCheck('secure-session', () async => true),
          UpdateIntegrityCheck('broken-store', () async => false),
          UpdateIntegrityCheck('throwing-store', () async => throw Exception()),
        ],
        preferences: prefs,
      );

      expect(report, isNotNull);
      expect(report!.fromBuild, 3);
      expect(report.toBuild, 4);
      expect(report.results, {
        'preferences': true,
        'secure-session': true,
        'broken-store': false,
        'throwing-store': false,
      });
      expect(report.allOk, isFalse);
      // 失败也只报告：构建号仍被推进，绝不触发数据清理。
      expect(prefs.getInt(UpdateDataIntegrity.previousBuildKey), 4);
    });
  });

  group('AppUpdateDeferStore', () {
    test('records the user choice with build number and timestamp',
        () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppUpdateDeferStore(await SharedPreferences.getInstance());

      expect(store.deferredBuild, isNull);
      expect(store.deferredAt, isNull);

      final at = DateTime.utc(2026, 8, 30, 12, 30);
      await store.record(4, at);

      expect(store.deferredBuild, 4);
      expect(store.deferredAt, at);
    });
  });

  test('defer store clear removes the suppressed build', () async {
    final prefs = SharedPreferences.getInstance();
    final store = AppUpdateDeferStore(await prefs);
    await store.record(18, DateTime.now());
    expect(store.deferredBuild, 18);

    await store.clear();
    expect(store.deferredBuild, isNull);
    expect(store.deferredAt, isNull);
  });
}
