import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/installation_marker.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('无标记时报告为未注册', () async {
    SharedPreferences.setMockInitialValues({});
    final marker = SharedPreferencesInstallationMarker(
        await SharedPreferences.getInstance());
    expect(await marker.isRegistered(), isFalse);
  });

  test('空值不算已注册', () async {
    SharedPreferences.setMockInitialValues(
        {SharedPreferencesInstallationMarker.key: ''});
    final marker = SharedPreferencesInstallationMarker(
        await SharedPreferences.getInstance());
    expect(await marker.isRegistered(), isFalse);
  });

  test('注册后持久化为非空值且可再次读出', () async {
    SharedPreferences.setMockInitialValues({});
    final marker = SharedPreferencesInstallationMarker(
        await SharedPreferences.getInstance());
    await marker.register();
    expect(await marker.isRegistered(), isTrue);
    // 重新读取同一个键，确认落盘的是非空值而不是仅存在于内存。
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(SharedPreferencesInstallationMarker.key), isNotEmpty);
  });
}
