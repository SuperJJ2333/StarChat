import 'installation_marker.dart';
import 'session_store.dart';

/// 启动时安装世代核对的结果。
enum InstallationResetOutcome {
  /// 标记已存在：同一安装的延续，未做任何清理。
  notNeeded,

  /// 全新安装：遗留已清除且标记已写入。
  cleared,

  /// 状态未落定：标记读取失败、清除失败或标记写入失败。调用方应继续启动，
  /// 但知道本次运行的本地状态没有得到保证。
  failed,
}

/// 让应用能区分"同一安装的延续"与"全新安装但钥匙串有残留"。
///
/// 必须在任何读取钥匙串遗留的动作之前运行：它决定了那些遗留是否还成立。
final class InstallationReconciler {
  InstallationReconciler({required this.marker, required this.store});

  final InstallationMarkerStore marker;
  final SecureSessionStore store;

  Future<InstallationResetOutcome> reconcile() async {
    final bool registered;
    try {
      registered = await marker.isRegistered();
    } catch (_) {
      // 不确定是否为全新安装时，绝不抹掉可能是有效的会话与密钥。
      return InstallationResetOutcome.failed;
    }
    if (registered) return InstallationResetOutcome.notNeeded;
    try {
      await store.clearInstallation();
    } catch (_) {
      // 清除未完成就不写标记，否则残留会被永久化，下次启动不再重试。
      // 部分清除是安全的：任一残留都不会让状态比修复前更差。
      return InstallationResetOutcome.failed;
    }
    try {
      await marker.register();
    } catch (_) {
      // 清除已生效，但标记未落定，下次启动会幂等地重跑一次清除。
      return InstallationResetOutcome.failed;
    }
    return InstallationResetOutcome.cleared;
  }
}
