import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// Gateway to the business API's app-release endpoint. The business API is
/// the single authority for release and force-update state; nothing here
/// derives update decisions from Matrix or client display state.
abstract interface class AppUpdateGateway {
  Future<Map<String, dynamic>> latestAppUpdate();
}

final class AppUpdateInfo {
  const AppUpdateInfo({
    required this.latestVersion,
    required this.latestBuild,
    required this.minSupportedBuild,
    required this.notes,
    required this.apkUrl,
  });

  factory AppUpdateInfo.fromMap(Map<String, dynamic> map) => AppUpdateInfo(
        latestVersion: map['latest_version']?.toString() ?? '',
        latestBuild: int.tryParse(map['latest_build']?.toString() ?? '') ?? 0,
        minSupportedBuild:
            int.tryParse(map['min_supported_build']?.toString() ?? '') ?? 0,
        notes: map['notes']?.toString() ?? '',
        apkUrl: map['apk_url']?.toString() ?? '',
      );

  final String latestVersion;
  final int latestBuild;
  final int minSupportedBuild;
  final String notes;
  final String apkUrl;

  bool get isConfigured => latestBuild > 0;
}

/// Parses the API payload; returns null when the server has no release
/// published (or the payload is malformed) so the caller can stay silent.
AppUpdateInfo? parseAppUpdate(Map<String, dynamic> map) {
  if (map['configured']?.toString() != 'true') return null;
  final info = AppUpdateInfo.fromMap(map);
  return info.isConfigured ? info : null;
}

/// 语义化版本比较：a>b 返回 1，相等返回 0，a<b 返回 -1；
/// 任一版本无法按点分整数解析时返回 null（调用方回退构建号比较）。
int? compareVersions(String a, String b) {
  if (a.trim().isEmpty || b.trim().isEmpty) return null;
  final pa = a.trim().split('.');
  final pb = b.trim().split('.');
  final length = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < length; i++) {
    final sa = i < pa.length ? pa[i] : '0';
    final sb = i < pb.length ? pb[i] : '0';
    final na = int.tryParse(sa);
    final nb = int.tryParse(sb);
    if (na == null || nb == null) return null;
    if (na != nb) return na > nb ? 1 : -1;
  }
  return 0;
}

/// The update the user should act on, or null when this build is current.
///
/// 优先**语义化比较版本名**（latest_version vs 当前版本名）：Android 分
/// ABI 包的 versionCode 带 `abiIndex*1000` 偏移，构建号比较对旧客户端
/// 永远失真；版本名比较与打包方案解耦。版本名不可解析时回退构建号。
AppUpdateInfo? resolvePendingUpdate({
  required AppUpdateInfo? info,
  required int currentBuild,
  String? currentVersion,
}) {
  if (info == null || !info.isConfigured) return null;
  final semantic = compareVersions(info.latestVersion, currentVersion ?? '');
  if (semantic != null) return semantic > 0 ? info : null;
  if (currentBuild >= info.latestBuild) return null;
  return info;
}

/// 强制更新：低于最低支持版本时，用户必须完成更新才能继续使用。
bool requiresForcedUpdate(AppUpdateInfo info, int currentBuild) =>
    currentBuild < info.minSupportedBuild;

/// Opens the download out of the app; overridable in tests.
Future<void> launchAppDownload(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.isAbsolute) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// 记录用户「稍后再说」的选择（版本号 + 时间），避免同一启动会话内重复
/// 打扰；下次启动仍按产品规则再次提醒。
final class AppUpdateDeferStore {
  AppUpdateDeferStore(this._prefs);

  static const _buildKey = 'update-deferred-build';
  static const _timeKey = 'update-deferred-at';

  final SharedPreferences _prefs;

  int? get deferredBuild => _prefs.getInt(_buildKey);
  DateTime? get deferredAt {
    final value = _prefs.getString(_timeKey);
    return value == null ? null : DateTime.tryParse(value);
  }

  Future<void> record(int build, DateTime at) async {
    await _prefs.setInt(_buildKey, build);
    await _prefs.setString(_timeKey, at.toIso8601String());
  }

  Future<void> clear() async {
    await _prefs.remove(_buildKey);
    await _prefs.remove(_timeKey);
  }
}
