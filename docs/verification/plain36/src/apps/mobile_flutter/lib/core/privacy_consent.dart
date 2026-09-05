import 'package:shared_preferences/shared_preferences.dart';

/// 隐私政策同意状态（个推初始化的前置门槛）。
///
/// 现状：登录页"同意用户协议和隐私政策"为会话内勾选（未持久化）——
/// 0.3.34 起登录成功后落盘；个推 SDK 第二段初始化（initialize）只在
/// 本标志为 true 时执行。未同意/拒绝授权只影响推送增强通道，
/// 聊天基本功能不受任何影响。
abstract interface class PrivacyConsentStore {
  Future<bool> accepted();

  Future<void> accept();
}

final class SharedPreferencesPrivacyConsentStore
    implements PrivacyConsentStore {
  const SharedPreferencesPrivacyConsentStore();

  static const prefsKey = 'privacy.agreement_accepted.v1';

  @override
  Future<bool> accepted() async {
    try {
      return (await SharedPreferences.getInstance()).getBool(prefsKey) == true;
    } catch (_) {
      return false; // 读取失败按未同意处理（隐私优先）。
    }
  }

  @override
  Future<void> accept() async {
    try {
      await (await SharedPreferences.getInstance()).setBool(prefsKey, true);
    } catch (_) {
      // 持久化失败：本次会话仍可用内存默认 false——保守处理。
    }
  }
}
