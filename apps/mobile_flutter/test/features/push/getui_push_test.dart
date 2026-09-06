import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/privacy_consent.dart';
import 'package:liuhetong_mobile/features/push/matrix_pusher_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 个推通道 Dart 侧边界：
/// - 同意门槛存储（未同意=false；accept 后=true）；
/// - appId 常量（服务端 bridge 的设备过滤键必须一致）；
/// - 标准网关路径与 provider=getui 通道选择。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PrivacyConsentStore：默认未同意；accept 后持久化', () async {
    SharedPreferences.setMockInitialValues({});
    const store = SharedPreferencesPrivacyConsentStore();
    expect(await store.accepted(), isFalse, reason: '默认未同意（隐私优先）');

    await store.accept();
    expect(await store.accepted(), isTrue);
    expect(
      (await SharedPreferences.getInstance())
          .getBool(SharedPreferencesPrivacyConsentStore.prefsKey),
      isTrue,
      reason: '同意必须持久化（个推 initialize 的前置门槛）',
    );
  });

  test('个推通道 appId 与服务端 getui-bridge 过滤键一致', () {
    expect(MatrixPusherService.appIdGetui, 'com.liuhetong.mobile.getui');
  });

  test('个推网关 notify 路径派生约定', () {
    final base = Uri.parse('https://liuhetong888.com');
    final notify = MatrixPusherService.getuiGatewayUrl(base);
    expect(notify.toString(),
        'https://liuhetong888.com/_matrix/push/v1/notify?provider=getui');
  });
}
