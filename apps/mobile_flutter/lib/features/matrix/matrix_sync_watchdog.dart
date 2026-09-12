import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' show Client, SyncStatus, SyncStatusUpdate;

import 'matrix_sync_recovery_controller.dart';

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
/// 断裂、数据库事务卡死）。SDK 会重试已返回的请求错误，却无法自行
/// 恢复没有完成或没有报错的悬挂循环。看门狗以"循环心跳"为准：健康循环每次长轮询都会发出
/// `waitingForResponse`（≤ 40 秒一次），心跳停跳即判定异常：
///
/// - 停跳 > [softStallThreshold]：踢一次 `oneShotSync`（覆盖循环活着
///   但请求悬挂的常见形态）；
/// - 停跳 > [hardStallThreshold]：`abortSync` 完成后重开 `backgroundSync`
///   强制重建循环；15 秒仅输出诊断，绝不在 SDK 清理未完成时抢跑，并补一次
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
    MatrixTransportMonitor? transport,
  })  : _clock = clock ?? DateTime.now,
        _transport = transport;

  final SyncWatchdogTarget target;
  final Duration interval;

  /// 无心跳判定为软停跳的阈值（健康长轮询 40s 一跳，2.5min 足够宽容）。
  @visibleForTesting
  final Duration softStallThreshold;

  /// 软踢后仍无心跳，强制重建循环的阈值。
  @visibleForTesting
  final Duration hardStallThreshold;

  final DateTime Function() _clock;
  final MatrixTransportMonitor? _transport;
  final ValueNotifier<MatrixConnectionStatus> connectionStatus =
      ValueNotifier(MatrixConnectionStatus.unknown);

  StreamSubscription<SyncStatusUpdate>? _subscription;
  Timer? _timer;
  Future<void>? _restarting;
  Future<void>? _softKicking;
  Timer? _abortDiagnosticTimer;
  bool _transportOffline = false;
  late final MatrixSyncRecoveryController? _recoveryController =
      _transport == null
          ? null
          : MatrixSyncRecoveryController(
              transport: _transport,
              onCandidate: _recoverFromTransport,
              onOffline: () => _setStatus(MatrixConnectionStatus.offline),
              onTransportStateChanged: (online) => _transportOffline = !online,
            );
  bool _disposed = false;
  DateTime _lastProgress = DateTime.now();

  void start() {
    if (_disposed || _timer != null) return;
    _lastProgress = _clock();
    _subscription = target.syncStatus.listen((update) {
      if (_disposed) return;
      // waitingForResponse 每轮长轮询必发，是最可靠的心跳；
      // finished/processing 视为额外进展。error 不算心跳——持续报错
      // 的循环同样需要被强制重建。
      if (update.status == SyncStatus.waitingForResponse ||
          update.status == SyncStatus.processing ||
          update.status == SyncStatus.finished) {
        _lastProgress = _clock();
      }
      if (update.status == SyncStatus.finished && !_transportOffline) {
        _setStatus(MatrixConnectionStatus.connected);
      } else if (update.status == SyncStatus.error &&
          connectionStatus.value != MatrixConnectionStatus.offline) {
        _setStatus(MatrixConnectionStatus.serviceUnavailable);
      }
    });
    _timer = Timer.periodic(interval, (_) => tick());
    _recoveryController?.start();
  }

  void onAppResumed() => _recoveryController?.onAppResumed();

  /// Starts (or joins) an awaited hard recovery for the current session.
  /// Product UI uses this rather than [onAppResumed] so its retry affordance
  /// remains disabled until the actual SDK abort/replacement sequence settles.
  Future<void> retry() {
    if (_disposed) return Future.value();
    final recovery = _recoveryController;
    return recovery?.retry() ?? _recoverFromTransport(true);
  }

  Future<void> _recoverFromTransport(bool forceRestart) {
    _setStatus(MatrixConnectionStatus.connecting);
    return forceRestart ? _restartLoop() : _softKick();
  }

  void _setStatus(MatrixConnectionStatus value) {
    if (!_disposed && connectionStatus.value != value) {
      connectionStatus.value = value;
    }
  }

  /// 看门狗拍：按停跳时长分级处置。测试可直接驱动。
  @visibleForTesting
  Future<void> tick() async {
    if (_disposed) return;
    if (_transportOffline) return;
    if (_restarting != null) return;
    final idle = _clock().difference(_lastProgress);
    if (idle <= softStallThreshold) return;
    if (idle <= hardStallThreshold) {
      debugPrint('[chatflow/syncwatchdog] sync stalled ${idle.inSeconds}s, '
          'kicking oneShotSync');
      unawaited(_softKick());
      return;
    }
    debugPrint('[chatflow/syncwatchdog] sync stalled ${idle.inSeconds}s, '
        'queuing serialized loop restart');
    _lastProgress = _clock(); // 重置阈值，避免连环重启。
    unawaited(_restartLoop());
  }

  Future<void> _restartLoop() {
    final existing = _restarting;
    if (existing != null) return existing;
    late final Future<void> restart;
    restart = _restartLoopSafely().whenComplete(() {
      if (identical(_restarting, restart)) _restarting = null;
    });
    return _restarting = restart;
  }

  Future<void> _restartLoopSafely() async {
    _abortDiagnosticTimer?.cancel();
    final diagnostic = Timer(const Duration(seconds: 15), () {
      if (!_disposed) {
        debugPrint('[chatflow/syncwatchdog] abortSync is still settling; '
            'waiting to avoid corrupting the replacement loop');
      }
    });
    _abortDiagnosticTimer = diagnostic;
    try {
      // The Matrix SDK clears its active-sync bookkeeping only after this
      // Future settles. Starting first can attach the replacement to the old
      // request, then let a late abort clear the replacement's state.
      await target.abortSync();
    } catch (_) {
      if (!_disposed &&
          !_transportOffline &&
          connectionStatus.value != MatrixConnectionStatus.offline) {
        _setStatus(MatrixConnectionStatus.serviceUnavailable);
      }
      return;
    } finally {
      diagnostic.cancel();
      if (identical(_abortDiagnosticTimer, diagnostic)) {
        _abortDiagnosticTimer = null;
      }
    }
    if (_disposed ||
        _transportOffline ||
        connectionStatus.value == MatrixConnectionStatus.offline) {
      return;
    }
    target.backgroundSync = true;
    if (_disposed ||
        _transportOffline ||
        connectionStatus.value == MatrixConnectionStatus.offline) {
      return;
    }
    unawaited(target
        .oneShotSync()
        .timeout(const Duration(seconds: 45))
        .catchError((_) {}));
  }

  Future<void> _softKick() {
    final existing = _softKicking;
    if (existing != null) return existing;
    late final Future<void> kick;
    kick = target
        .oneShotSync()
        .timeout(
          const Duration(seconds: 45),
          onTimeout: () => debugPrint('[chatflow/syncwatchdog] oneShotSync '
              'kick timed out; escalating on next tick'),
        )
        .catchError((_) {})
        .whenComplete(() {
      if (identical(_softKicking, kick)) _softKicking = null;
    });
    return _softKicking = kick;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _abortDiagnosticTimer?.cancel();
    _abortDiagnosticTimer = null;
    _recoveryController?.dispose();
    connectionStatus.dispose();
    unawaited(_subscription?.cancel());
    _subscription = null;
  }
}
