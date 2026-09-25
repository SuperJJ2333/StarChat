import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/app_connection_status.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_sync_recovery_controller.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_sync_phase_metrics.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_sync_watchdog.dart';
import 'package:matrix/matrix.dart' show SyncStatus, SyncStatusUpdate;

/// BUG（后台/锁屏收不到通知第四次修复）：SDK 同步循环在后台可能悬挂
/// （连接黑洞/续环断裂/事务卡死），无任何自愈——看门狗以循环心跳为准，
/// 停跳先踢一次 oneShotSync，仍停跳强制 abortSync + 重启循环。
void main() {
  SyncStatusUpdate status(SyncStatus s) => SyncStatusUpdate(s);

  test('release-style watchdog stall records no detailed log', () async {
    final previous = debugPrint;
    final lines = <String>[];
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) lines.add(message);
    };
    addTearDown(() => debugPrint = previous);
    final target = _FakeWatchdogTarget();
    final watchdog = MatrixSyncWatchdog(
      target: target,
      clock: target.clock.now,
      syncPhaseMetrics:
          MatrixSyncPhaseMetrics(metrics: PerformanceMetrics(enabled: false)),
    );
    watchdog.start();
    target.clock.elapse(const Duration(minutes: 3));
    await watchdog.tick();
    await _settle();
    expect(target.oneShots, 1);
    expect(lines, isEmpty);
    watchdog.dispose();
  });

  test('diagnostic watchdog stall uses the unified matrix tag', () async {
    final previous = debugPrint;
    final lines = <String>[];
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) lines.add(message);
    };
    addTearDown(() => debugPrint = previous);
    final target = _FakeWatchdogTarget();
    final watchdog = MatrixSyncWatchdog(
      target: target,
      clock: target.clock.now,
      syncPhaseMetrics:
          MatrixSyncPhaseMetrics(metrics: PerformanceMetrics(enabled: true)),
    );
    watchdog.start();
    target.clock.elapse(const Duration(minutes: 3));
    await watchdog.tick();
    await _settle();
    expect(lines, isNotEmpty);
    expect(lines, everyElement(startsWith('[chatflow/matrix]')));
    watchdog.dispose();
  });

  test('transport availability follows only actual transport observations',
      () async {
    final target = _FakeWatchdogTarget();
    final transport = _FakeTransport({MatrixTransport.wifi});
    final watchdog = MatrixSyncWatchdog(target: target, transport: transport);
    expect(watchdog.transportAvailable.value, isNull);
    watchdog.start();
    await _settle();
    await _settle();
    expect(watchdog.transportAvailable.value, isTrue);

    target.emit(status(SyncStatus.error));
    await _settle();
    expect(watchdog.connectionStatus.value,
        MatrixConnectionStatus.serviceUnavailable);
    expect(watchdog.transportAvailable.value, isTrue,
        reason: 'Matrix sync failure is not device transport failure');

    transport.emit({});
    await _settle();
    expect(watchdog.transportAvailable.value, isFalse);
    transport.emit({MatrixTransport.wifi});
    await _settle();
    expect(watchdog.transportAvailable.value, isTrue);
    watchdog.dispose();
  });

  test('without a transport monitor sync statuses leave availability unknown',
      () async {
    final target = _FakeWatchdogTarget();
    final watchdog = MatrixSyncWatchdog(target: target);
    watchdog.start();
    target.emit(status(SyncStatus.finished));
    target.emit(status(SyncStatus.error));
    await _settle();
    expect(watchdog.transportAvailable.value, isNull);
    watchdog.dispose();
  });

  test('sync errors and reconnects retain the age of the last healthy cycle',
      () async {
    final target = _FakeWatchdogTarget();
    final metrics = PerformanceMetrics(enabled: true);
    final watchdog = MatrixSyncWatchdog(
      target: target,
      clock: target.clock.now,
      syncPhaseMetrics: MatrixSyncPhaseMetrics(metrics: metrics),
    );
    watchdog.start();
    expect(watchdog.lastHealthySyncAge, isNull);

    target.emit(status(SyncStatus.finished));
    await _settle();
    expect(watchdog.lastHealthySyncAge, Duration.zero);
    target.clock.elapse(const Duration(seconds: 7));
    expect(watchdog.lastHealthySyncAge, const Duration(seconds: 7));

    target.emit(status(SyncStatus.error));
    await _settle();
    expect(watchdog.connectionStatus.value,
        MatrixConnectionStatus.serviceUnavailable);
    target.clock.elapse(const Duration(seconds: 1));
    target.emit(status(SyncStatus.finished));
    await _settle();
    final counters = metrics.snapshot()['counters'] as Map;
    expect(counters['syncErrors'], 1);
    expect(counters['syncReconnects'], 1);
    expect(watchdog.lastHealthySyncAge, Duration.zero);
    watchdog.dispose();
  });

  test('sync error and reconnect counts survive disabled local metrics',
      () async {
    final target = _FakeWatchdogTarget();
    final metrics = PerformanceMetrics(enabled: false);
    final watchdog = MatrixSyncWatchdog(
      target: target,
      clock: target.clock.now,
      syncPhaseMetrics: MatrixSyncPhaseMetrics(metrics: metrics),
    );
    watchdog.start();
    expect(watchdog.syncErrorCount, 0);
    expect(watchdog.reconnectCount, 0);

    target.emit(status(SyncStatus.finished));
    await _settle();
    expect(watchdog.reconnectCount, 0,
        reason: 'first healthy sync is not a reconnect');
    target.emit(status(SyncStatus.error));
    target.emit(status(SyncStatus.error));
    await _settle();
    expect(watchdog.syncErrorCount, 2);
    expect(watchdog.reconnectCount, 0);
    target.emit(status(SyncStatus.finished));
    await _settle();
    expect(watchdog.reconnectCount, 1);
    target.emit(status(SyncStatus.finished));
    await _settle();
    expect(watchdog.reconnectCount, 1,
        reason: 'healthy status repeats do not count as reconnects');
    expect(metrics.snapshot()['counters'], isEmpty);
    watchdog.dispose();
  });

  test('counts actual soft kicks and hard restart attempts once', () async {
    final target = _FakeWatchdogTarget()..holdOneShot = true;
    final metrics = PerformanceMetrics(enabled: true);
    final watchdog = MatrixSyncWatchdog(
      target: target,
      clock: target.clock.now,
      syncPhaseMetrics: MatrixSyncPhaseMetrics(metrics: metrics),
    );
    watchdog.start();
    target.emit(status(SyncStatus.waitingForResponse));
    await _settle();
    target.clock.elapse(const Duration(minutes: 3));
    await watchdog.tick();
    await watchdog.tick();
    await _settle();
    expect((metrics.snapshot()['counters'] as Map)['syncSoftKicks'], 1);
    target.releaseOneShot();
    await _settle();

    target.clock.elapse(const Duration(minutes: 3));
    await watchdog.tick();
    await _settle();
    expect((metrics.snapshot()['counters'] as Map)['syncHardRestarts'], 1);
    watchdog.dispose();
  });

  test('resume action counts remain available when metrics are disabled',
      () async {
    final target = _FakeWatchdogTarget()..holdOneShot = true;
    final metrics = PerformanceMetrics(enabled: false);
    final watchdog = MatrixSyncWatchdog(
      target: target,
      clock: target.clock.now,
      syncPhaseMetrics: MatrixSyncPhaseMetrics(metrics: metrics),
    );
    expect(watchdog.softKickCount, 0);
    expect(watchdog.hardRestartCount, 0);
    watchdog.start();
    target.emit(status(SyncStatus.waitingForResponse));
    await _settle();

    target.clock.elapse(const Duration(minutes: 3));
    await watchdog.tick();
    await watchdog.tick();
    await _settle();
    expect(watchdog.softKickCount, 1,
        reason: 'joining an in-flight kick must not count twice');
    expect(watchdog.hardRestartCount, 0);
    target.releaseOneShot();
    await _settle();

    target.clock.elapse(const Duration(minutes: 3));
    await watchdog.tick();
    await _settle();
    expect(watchdog.softKickCount, 1);
    expect(watchdog.hardRestartCount, 1);
    expect(metrics.snapshot()['counters'], isEmpty,
        reason: 'release action counts must not depend on metrics sampling');
    watchdog.dispose();
  });

  test('健康循环（心跳持续）不采取任何行动', () async {
    final target = _FakeWatchdogTarget();
    final watchdog =
        MatrixSyncWatchdog(target: target, clock: target.clock.now);
    watchdog.start();
    target.emit(status(SyncStatus.waitingForResponse));
    target.clock.elapse(const Duration(minutes: 1));
    await watchdog.tick();
    target.emit(status(SyncStatus.waitingForResponse));
    target.clock.elapse(const Duration(minutes: 1));
    await watchdog.tick();

    expect(target.oneShots, 0);
    expect(target.restarts, 0);
    watchdog.dispose();
  });

  test('停跳超过软阈值 → 踢一次 oneShotSync，不重启', () async {
    final target = _FakeWatchdogTarget();
    final watchdog =
        MatrixSyncWatchdog(target: target, clock: target.clock.now);
    watchdog.start();
    target.emit(status(SyncStatus.waitingForResponse));
    target.clock.elapse(const Duration(minutes: 3));
    await watchdog.tick();

    expect(target.oneShots, 1, reason: '软阈值触发一次性同步');
    expect(target.restarts, 0);
    watchdog.dispose();
  });

  test('停跳超过硬阈值 → abortSync + 重启后台同步循环', () async {
    final target = _FakeWatchdogTarget();
    final watchdog =
        MatrixSyncWatchdog(target: target, clock: target.clock.now);
    watchdog.start();
    target.emit(status(SyncStatus.waitingForResponse));
    target.clock.elapse(const Duration(minutes: 6));
    await watchdog.tick();
    await _settle();

    expect(target.restarts, 1, reason: '硬阈值必须强制重建循环');
    expect(target.backgroundSyncFlag, isTrue, reason: '重启后循环必须恢复运行');
    watchdog.dispose();
  });

  test('心跳恢复后阈值重新计时（不会连环重启）', () async {
    final target = _FakeWatchdogTarget();
    final watchdog =
        MatrixSyncWatchdog(target: target, clock: target.clock.now);
    watchdog.start();
    target.emit(status(SyncStatus.waitingForResponse));
    target.clock.elapse(const Duration(minutes: 3));
    await watchdog.tick();
    expect(target.oneShots, 1);

    // 心跳恢复：后续 tick 不再行动。
    target.emit(status(SyncStatus.finished));
    target.clock.elapse(const Duration(minutes: 1));
    await watchdog.tick();
    expect(target.oneShots, 1);
    expect(target.restarts, 0);
    watchdog.dispose();
  });

  test('abortSync 未完成时不启动可能被其迟到清理破坏的新循环', () async {
    final target = _FakeWatchdogTarget()..hangAbort = true;
    final watchdog =
        MatrixSyncWatchdog(target: target, clock: target.clock.now);
    watchdog.start();
    target.emit(status(SyncStatus.waitingForResponse));
    target.clock.elapse(const Duration(minutes: 6));
    await watchdog.tick();
    await _settle();

    expect(target.restarts, 0);
    expect(target.backgroundSyncFlag, isFalse);
    watchdog.dispose();
  });

  test('硬恢复在 abortSync 完成前不启动替代同步循环', () async {
    final target = _FakeWatchdogTarget()..holdAbort = true;
    final watchdog =
        MatrixSyncWatchdog(target: target, clock: target.clock.now);
    watchdog.start();
    target.emit(status(SyncStatus.waitingForResponse));
    target.clock.elapse(const Duration(minutes: 6));

    final recovering = watchdog.tick();
    await Future<void>.delayed(Duration.zero);

    expect(target.operations, ['abort'],
        reason: 'SDK abort clears its active-sync state asynchronously; '
            'starting first can attach the new loop to the old request');

    target.releaseAbort();
    await recovering;
    await _settle();
    expect(target.operations, ['abort', 'background:true', 'oneShot']);
    watchdog.dispose();
  });

  test('停跳的软踢在前一次 oneShotSync 未完成时不会叠加', () async {
    final target = _FakeWatchdogTarget()..holdOneShot = true;
    final watchdog =
        MatrixSyncWatchdog(target: target, clock: target.clock.now);
    watchdog.start();
    target.emit(status(SyncStatus.waitingForResponse));
    target.clock.elapse(const Duration(minutes: 3));
    await watchdog.tick();
    await _settle();
    target.clock.elapse(const Duration(minutes: 1));
    await watchdog.tick();
    await _settle();

    expect(target.oneShots, 1);
    target.releaseOneShot();
    watchdog.dispose();
  });

  test('释放后的迟到 abort 不会重启已注销会话', () async {
    final target = _FakeWatchdogTarget()..holdAbort = true;
    final watchdog =
        MatrixSyncWatchdog(target: target, clock: target.clock.now);
    watchdog.start();
    target.emit(status(SyncStatus.waitingForResponse));
    target.clock.elapse(const Duration(minutes: 6));
    await watchdog.tick();
    await _settle();
    watchdog.dispose();
    target.releaseAbort();
    await _settle();

    expect(target.restarts, 0);
    expect(target.oneShots, 0);
  });

  test('离线后迟到 finished 不会把状态改回 connected，也不会重启', () async {
    final target = _FakeWatchdogTarget();
    final transport = _FakeTransport({MatrixTransport.wifi});
    final watchdog = MatrixSyncWatchdog(
      target: target,
      clock: target.clock.now,
      transport: transport,
    );
    watchdog.start();
    await _settle();
    await _settle();
    transport.emit({});
    await _settle();
    target.emit(status(SyncStatus.finished));
    await _settle();
    target.clock.elapse(const Duration(minutes: 6));
    await watchdog.tick();

    expect(watchdog.connectionStatus.value, MatrixConnectionStatus.offline);
    expect(target.restarts, 0);
    watchdog.dispose();
  });

  test('dispose is idempotent when AppHome closes resources twice', () {
    final target = _FakeWatchdogTarget();
    final watchdog =
        MatrixSyncWatchdog(target: target, clock: target.clock.now);

    watchdog.start();
    watchdog.dispose();

    expect(watchdog.dispose, returnsNormally);
  });

  test('hub retry waits for the watchdog recovery and remains singleflight',
      () async {
    final target = _FakeWatchdogTarget()..holdAbort = true;
    final watchdog =
        MatrixSyncWatchdog(target: target, clock: target.clock.now);
    final hub = AppConnectionStatusHub.shared;
    final owner = Object();
    watchdog.start();
    hub.bind<MatrixConnectionStatus>(
      owner,
      watchdog.connectionStatus,
      (value) => switch (value) {
        MatrixConnectionStatus.unknown => AppConnectionStatus.unknown,
        MatrixConnectionStatus.connecting => AppConnectionStatus.connecting,
        MatrixConnectionStatus.offline => AppConnectionStatus.offline,
        MatrixConnectionStatus.connected => AppConnectionStatus.connected,
        MatrixConnectionStatus.serviceUnavailable =>
          AppConnectionStatus.serviceUnavailable,
      },
      onRetry: watchdog.retry,
    );

    final first = hub.retry();
    final second = hub.retry();
    await _settle();
    expect(identical(first, second), isTrue);
    expect(target.operations, ['abort']);
    var settled = false;
    first.whenComplete(() => settled = true);
    await _settle();
    expect(settled, isFalse, reason: 'retry must await abort/replacement');

    target.releaseAbort();
    await first;
    expect(target.operations, ['abort', 'background:true', 'oneShot']);
    hub.unbind(owner);
    watchdog.dispose();
  });

  test('manual retry rechecks an offline transport and recovers when online',
      () async {
    final target = _FakeWatchdogTarget();
    final transport = _FakeTransport({});
    final watchdog = MatrixSyncWatchdog(
      target: target,
      clock: target.clock.now,
      transport: transport,
    );
    watchdog.start();
    await _settle();
    expect(watchdog.connectionStatus.value, MatrixConnectionStatus.offline);

    transport.setCurrent({MatrixTransport.wifi});
    await watchdog.retry();

    expect(target.operations, ['abort', 'background:true', 'oneShot']);
    expect(watchdog.connectionStatus.value, MatrixConnectionStatus.connecting);
    watchdog.dispose();
  });

  test('failed abort settles retry with an actionable unavailable status',
      () async {
    final target = _FakeWatchdogTarget()..failAbort = true;
    final watchdog =
        MatrixSyncWatchdog(target: target, clock: target.clock.now);
    watchdog.start();

    await watchdog.retry();

    expect(target.aborts, 1);
    expect(watchdog.connectionStatus.value,
        MatrixConnectionStatus.serviceUnavailable);
    watchdog.dispose();
  });

  test('going offline while abort settles prevents a replacement loop',
      () async {
    final target = _FakeWatchdogTarget()..holdAbort = true;
    final transport = _FakeTransport({MatrixTransport.wifi});
    final watchdog = MatrixSyncWatchdog(
      target: target,
      clock: target.clock.now,
      transport: transport,
    );
    watchdog.start();
    await _settle();
    await _settle();
    target.emit(status(SyncStatus.waitingForResponse));
    target.clock.elapse(const Duration(minutes: 6));
    await watchdog.tick();
    await _settle();
    transport.emit({});
    await _settle();
    expect(watchdog.connectionStatus.value, MatrixConnectionStatus.offline);
    expect(target.restarts, 0);
    final oneShotsBeforeAbortSettles = target.oneShots;

    target.releaseAbort();
    await _settle();

    expect(target.restarts, 0);
    expect(target.oneShots, oneShotsBeforeAbortSettles,
        reason: 'an offline abort must not schedule the replacement sync');
    watchdog.dispose();
  });
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

final class _FakeClock {
  DateTime _now = DateTime(2026, 9, 3, 12);
  DateTime now() => _now;
  void elapse(Duration d) => _now = _now.add(d);
}

final class _FakeWatchdogTarget implements SyncWatchdogTarget {
  final clock = _FakeClock();
  final _controller = StreamController<SyncStatusUpdate>.broadcast();
  var oneShots = 0;
  var restarts = 0;
  var aborts = 0;
  bool backgroundSyncFlag = false;
  bool hangAbort = false;
  bool holdAbort = false;
  bool holdOneShot = false;
  bool failAbort = false;
  Completer<void>? _abortGate;
  Completer<void>? _oneShotGate;
  final operations = <String>[];

  void emit(SyncStatusUpdate update) => _controller.add(update);

  @override
  Stream<SyncStatusUpdate> get syncStatus => _controller.stream;

  @override
  Future<void> oneShotSync() async {
    oneShots++;
    operations.add('oneShot');
    if (holdOneShot) await (_oneShotGate ??= Completer<void>()).future;
  }

  @override
  Future<void> abortSync() async {
    aborts++;
    operations.add('abort');
    if (failAbort) throw StateError('abort failed');
    if (holdAbort) await (_abortGate ??= Completer<void>()).future;
    if (hangAbort) {
      // 模拟 abortSync 卡死（如事务悬挂）。
      await Completer<void>().future;
    }
  }

  @override
  set backgroundSync(bool enabled) {
    backgroundSyncFlag = enabled;
    operations.add('background:$enabled');
    if (enabled) restarts++;
  }

  void releaseAbort() => (_abortGate ??= Completer<void>()).complete();
  void releaseOneShot() => (_oneShotGate ??= Completer<void>()).complete();
}

final class _FakeTransport implements MatrixTransportMonitor {
  _FakeTransport(Set<MatrixTransport> initial) : _current = initial;

  Set<MatrixTransport> _current;
  final _changes = StreamController<Set<MatrixTransport>>.broadcast();

  @override
  Future<Set<MatrixTransport>> check() async => _current;

  void setCurrent(Set<MatrixTransport> value) => _current = value;

  @override
  Stream<Set<MatrixTransport>> get changes => _changes.stream;

  void emit(Set<MatrixTransport> value) => _changes.add(value);
}
