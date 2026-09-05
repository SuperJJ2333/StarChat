import 'package:shared_preferences/shared_preferences.dart';

typedef UpdateIntegrityProbe = Future<bool> Function();

final class UpdateIntegrityCheck {
  const UpdateIntegrityCheck(this.name, this.probe);

  final String name;
  final UpdateIntegrityProbe probe;
}

final class UpdateDataIntegrityReport {
  const UpdateDataIntegrityReport({
    required this.fromBuild,
    required this.toBuild,
    required this.results,
  });

  final int fromBuild;
  final int toBuild;
  final Map<String, bool> results;

  bool get allOk => results.values.every((ok) => ok);
}

/// 版本更新后的数据完整性校验。
///
/// 安装包升级由操作系统保留应用私有数据（同签名是前提，发布签名由
/// `key.properties` 保证）；本服务在检测到版本变化时验证关键本地存储
/// 仍然可读并记录最新版本号。任何探针失败都**只报告、绝不清理或重置
/// 数据**。首次安装（无历史版本记录）不产出报告。
final class UpdateDataIntegrity {
  UpdateDataIntegrity._();

  static const previousBuildKey = 'last-run-build';

  /// Returns null when no version change happened (including first run).
  static Future<UpdateDataIntegrityReport?> verify({
    required int currentBuild,
    required List<UpdateIntegrityCheck> checks,
    SharedPreferences? preferences,
  }) async {
    final prefs = preferences ?? await SharedPreferences.getInstance();
    final from = prefs.getInt(previousBuildKey);
    if (from == null) {
      // 首次安装：记录基线版本号，之后的版本变化才会触发校验。
      await prefs.setInt(previousBuildKey, currentBuild);
      return null;
    }
    if (from == currentBuild) return null;
    final results = <String, bool>{};
    for (final check in checks) {
      results[check.name] = await _safe(check.probe);
    }
    await prefs.setInt(previousBuildKey, currentBuild);
    return UpdateDataIntegrityReport(
      fromBuild: from,
      toBuild: currentBuild,
      results: results,
    );
  }

  static Future<bool> _safe(UpdateIntegrityProbe probe) async {
    try {
      return await probe();
    } catch (_) {
      return false;
    }
  }
}
