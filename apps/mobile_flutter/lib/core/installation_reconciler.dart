import 'installation_container_probe.dart';
import 'installation_marker.dart';
import 'session_store.dart';

/// 启动时安装世代核对的结果。
enum InstallationResetOutcome {
  /// 标记已存在：同一安装的延续，未做任何清理。
  notNeeded,

  /// 标记缺失但容器仍有上一次安装的加密库：覆盖升级的延续。
  /// 只播种了标记，未删除任何密钥。
  adopted,

  /// 全新安装：遗留已清除且标记已写入。
  cleared,

  /// 状态未落定：标记读取、容器探测、清除或播种中任一步失败。
  /// 注意只有"清除失败"意味着遗留仍在；读取或探测失败时什么都没动。
  failed,
}

/// 让应用能区分"同一安装的延续"与"全新安装但钥匙串有残留"。
///
/// 必须在任何读取钥匙串遗留的动作之前运行：它决定了那些遗留是否还成立。
///
/// 标记由本变更引入，所以存量安装升级时标记必然缺失而容器完好。仅凭标记缺失
/// 就清除会删掉仍在使用的数据库密钥，因此还要用容器产物做一次证据判断。
final class InstallationReconciler {
  InstallationReconciler({
    required this.marker,
    required this.probe,
    required this.store,
  });

  final InstallationMarkerStore marker;
  final InstallationContainerProbe probe;
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

    final bool continuation;
    try {
      continuation = await probe.hasPreviousMatrixStore();
    } catch (_) {
      // 探测回答的是"密钥是否还有效"，探测不出来就不能删任何东西。
      return InstallationResetOutcome.failed;
    }
    if (continuation) {
      // 覆盖升级：容器完好意味着这些密钥仍在使用。只播种标记。
      try {
        await marker.register();
      } catch (_) {
        return InstallationResetOutcome.failed;
      }
      return InstallationResetOutcome.adopted;
    }

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
