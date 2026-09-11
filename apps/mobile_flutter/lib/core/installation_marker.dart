import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// 安装世代标记。存放位置必须随应用卸载一起消失：iOS 落 NSUserDefaults、
/// Android 落应用数据，两端都会在卸载时清除。钥匙串不会，因此不能用它承载
/// 这个判断。
abstract interface class InstallationMarkerStore {
  Future<bool> isRegistered();
  Future<void> register();
}

final class SharedPreferencesInstallationMarker
    implements InstallationMarkerStore {
  SharedPreferencesInstallationMarker(this._preferences);

  static const key = 'changliao.installation.v1';

  final SharedPreferences _preferences;

  @override
  Future<bool> isRegistered() async {
    final value = _preferences.getString(key);
    return value != null && value.isNotEmpty;
  }

  @override
  Future<void> register() async {
    // 写入随机值而不是布尔值：空串或空白值不能被误读成"已注册"。
    final value = base64UrlEncode(
      List<int>.generate(24, (_) => Random.secure().nextInt(256)),
    );
    if (!await _preferences.setString(key, value)) {
      throw StateError('Installation marker was not persisted');
    }
  }
}
