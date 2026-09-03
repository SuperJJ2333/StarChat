import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' show Client, SyncStatus, SyncStatusUpdate;

/// 同步循环看门狗目标抽象（可注入测试）。
abstract interface class SyncWatchdogTarget {
  /// SDK 同步状态流：健康循环每次长轮询都会发 waitingForResponse。
  Stream<SyncStatusUpdate> get syncStatus;

  /// 立即执行一次同步；已有同步在途时复用该请求。
  Future<void> oneShotSync();

  /// 黑洞化在途同步并停止后台循环（可重入）。
  Future<void> abortSync();

  /// 置 true 重新启动后台同步循环。
  set backgroundSync(bool enabled);
}

final class ClientSyncWatchdogTarget implements SyncWatchdogTarget {
  const ClientSyncWatchdogTarget(this._client);
  final Client _client;

  @override
  Stream<SyncStatusUpdate> get syncStatus => _client.onSyncStatus.stream;

  @override
  Future<void> oneShotSync() => _client.oneShotSync();

  @override
  Future<void> abortSync() => _client.abortSync();

  @override
  set backgroundSync(bool enabled) => _client.backgroundSync = enabled;
}

/// Matrix 同步循环看门狗（后台/锁屏通知 BUG 第四次修复）。
///
/// 真机病理：退后台后同步循环可能整体悬挂（长轮询连接黑洞、SDK 续环
/// 断裂、数据库事务卡死），且 SDK 无任何自愈——消息只能等回前台才被
/// 拉到。看门狗以"循环心跳"为准：健康循环每次长轮询都会发出
/// `waitingForResponse`（≤ 40 秒一次），心跳停跳即判定异常：
///
/// - 停跳 > [softStallThreshold]：踢一次 `oneShotSync`（覆盖循环活着
///   但请求悬挂的常见形态）；
/// - 停跳 > [hardStallThreshold]：`abortSync`（15s 超时兜底，事务卡死
///   也不阻断）后重开 `backgroundSync` 强制重建循环，并补一次
///   `oneShotSync` 立即对账漏掉的消息。
///
/// 所有行动经 debugPrint 打 `chatflow/syncwatchdog` 标签（release 构建
/// logcat 可见），真机复现时可据此定位悬挂形态。
final class MatrixSyncWatchdog {
  MatrixSyncWatchdog({
    required this.target,
    DateTime Function()? clock,
    this.interval = const Duration(minutes: 1),
    this.softStallThreshold = const Duration(minutes: 2, seconds: 30),
    this.hardStallThreshold = const Duration(minutes: 5),
  }) : _clock = clock ?? DateTime.now;

  final SyncWatchdogTarget target;
  final Duration interval;

  /// 无心跳判定为软停跳的阈值（健康长轮询 40s 一跳，2.5min 足够宽容）。
  @visibleForTesting
  final Duration softStallThreshold;

  /// 软踢后仍无心跳，强制重建循环的阈值。
  @visibleForTesting
  final Duration hardStallThreshold;

  final DateTime Function() _clock;

  StreamSubscription<SyncStatusUpdate>? _subscription;
  Timer? _timer;
  DateTime _lastProgress = DateTime.now();

  void start() {
    if (_timer != null) return;
    _lastProgress = _clock();
    _subscription = target.syncStatus.listen((update) {
      // waitingForResponse 每轮长轮询必发，是最可靠的心跳；
      // finished/processing 视为额外进展。error 不算心跳——持续报错
      // 的循环同样需要被强制重建。
      if (update.status == SyncStatus.waitingForResponse ||
          update.status == SyncStatus.processing ||
          update.status == SyncStatus.finished) {
        _lastProgress = _clock();
      }
    });
    _timer = Timer.periodic(interval, (_) => tick());
  }

  /// 看门狗拍：按停跳时长分级处置。测试可直接驱动。
  @visibleForTesting
  Future<void> tick() async {
    final idle = _clock().difference(_lastProgress);
    if (idle <= softStallThreshold) return;
    if (idle <= hardStallThreshold) {
      debugPrint('[chatflow/syncwatchdog] sync stalled ${idle.inSeconds}s, '
          'kicking oneShotSync');
      unawaited(target.oneShotSync().timeout(
        const Duration(seconds: 45),
        onTimeout: () => debugPrint('[chatflow/syncwatchdog] oneShotSync '
            'kick timed out; escalating on next tick'),
      ).catchError((_) {}));
      return;
    }
    debugPrint('[chatflow/syncwatchdog] sync stalled ${idle.inSeconds}s, '
        'forcing loop restart (abortSync + backgroundSync)');
    _lastProgress = _clock(); // 重置阈值，避免连环重启。
    unawaited(target.abortSync().timeout(
      const Duration(seconds: 15),
      onTimeout: () => debugPrint('[chatflow/syncwatchdog] abortSync timed '
          'out (hung transaction?); restarting anyway'),
    ).catchError((_) {}));
    target.backgroundSync = true;
    unawaited(target.oneShotSync().timeout(
      const Duration(seconds: 45),
    ).catchError((_) {}));
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
  }
}
