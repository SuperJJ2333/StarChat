import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_sync_watchdog.dart';
import 'package:matrix/matrix.dart' show SyncStatus, SyncStatusUpdate;

/// BUG（后台/锁屏收不到通知第四次修复）：SDK 同步循环在后台可能悬挂
/// （连接黑洞/续环断裂/事务卡死），无任何自愈——看门狗以循环心跳为准，
/// 停跳先踢一次 oneShotSync，仍停跳强制 abortSync + 重启循环。
void main() {
  SyncStatusUpdate status(SyncStatus s) => SyncStatusUpdate(s);

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

  test('abortSync 卡死（超时）不阻断重启', () async {
    final target = _FakeWatchdogTarget()..hangAbort = true;
    final watchdog =
        MatrixSyncWatchdog(target: target, clock: target.clock.now);
    watchdog.start();
    target.emit(status(SyncStatus.waitingForResponse));
    target.clock.elapse(const Duration(minutes: 6));
    await watchdog.tick();

    expect(target.restarts, 1);
    expect(target.backgroundSyncFlag, isTrue);
    watchdog.dispose();
  });
}

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

  void emit(SyncStatusUpdate update) => _controller.add(update);

  @override
  Stream<SyncStatusUpdate> get syncStatus => _controller.stream;

  @override
  Future<void> oneShotSync() async => oneShots++;

  @override
  Future<void> abortSync() async {
    aborts++;
    if (hangAbort) {
      // 模拟 abortSync 卡死（如事务悬挂）。
      await Completer<void>().future;
    }
  }

  @override
  set backgroundSync(bool enabled) {
    backgroundSyncFlag = enabled;
    if (enabled) restarts++;
  }
}
