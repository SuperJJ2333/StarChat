import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_sync_phase_metrics.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_sync_watchdog.dart';
import 'package:matrix/matrix.dart' show SyncStatus, SyncStatusUpdate;

void main() {
  test('records one closed sync cycle using the first processing transition',
      () {
    var now = 100;
    final metrics = PerformanceMetrics(enabled: true);
    final phases = MatrixSyncPhaseMetrics(metrics: metrics, clockUs: () => now);

    phases.record(SyncStatus.waitingForResponse);
    now = 500;
    phases.record(SyncStatus.processing);
    now = 700;
    phases.record(SyncStatus.processing);
    now = 900;
    phases.record(SyncStatus.cleaningUp);
    now = 1200;
    phases.record(SyncStatus.finished);

    final operations = metrics.snapshot()['operations'] as Map;
    expect((operations['syncResponseWait'] as Map)['maxUs'], 400);
    expect((operations['syncProcessing'] as Map)['maxUs'], 400);
    expect((operations['syncCleanup'] as Map)['maxUs'], 300);
  });

  test('error, a new waiting phase, and dispose discard partial cycles', () {
    var now = 0;
    final metrics = PerformanceMetrics(enabled: true);
    final phases = MatrixSyncPhaseMetrics(metrics: metrics, clockUs: () => now);

    phases.record(SyncStatus.waitingForResponse);
    now = 10;
    phases.record(SyncStatus.processing);
    phases.record(SyncStatus.error);
    phases.record(SyncStatus.waitingForResponse);
    now = 20;
    phases.record(SyncStatus.processing);
    phases.dispose();
    phases.record(SyncStatus.cleaningUp);
    phases.record(SyncStatus.finished);

    expect(metrics.snapshot()['operations'], isEmpty);
  });

  test('a processing status after cleanup discards the malformed cycle', () {
    var now = 0;
    final metrics = PerformanceMetrics(enabled: true);
    final phases = MatrixSyncPhaseMetrics(metrics: metrics, clockUs: () => now);

    phases.record(SyncStatus.waitingForResponse);
    now = 10;
    phases.record(SyncStatus.processing);
    now = 20;
    phases.record(SyncStatus.cleaningUp);
    now = 30;
    phases.record(SyncStatus.processing);
    now = 40;
    phases.record(SyncStatus.finished);

    expect(metrics.snapshot()['operations'], isEmpty);
  });

  test('a new waiting status starts a new cycle instead of stitching timing',
      () {
    var now = 0;
    final metrics = PerformanceMetrics(enabled: true);
    final phases = MatrixSyncPhaseMetrics(metrics: metrics, clockUs: () => now);

    phases.record(SyncStatus.waitingForResponse);
    now = 10;
    phases.record(SyncStatus.processing);
    now = 100;
    phases.record(SyncStatus.waitingForResponse);
    now = 120;
    phases.record(SyncStatus.processing);
    now = 160;
    phases.record(SyncStatus.cleaningUp);
    now = 180;
    phases.record(SyncStatus.finished);

    final operations = metrics.snapshot()['operations'] as Map;
    expect((operations['syncResponseWait'] as Map)['maxUs'], 20);
    expect((operations['syncProcessing'] as Map)['maxUs'], 40);
    expect((operations['syncCleanup'] as Map)['maxUs'], 20);
  });

  test('disabled metrics never retain sync timings', () {
    final phases = MatrixSyncPhaseMetrics(
      metrics: PerformanceMetrics(enabled: false),
      clockUs: () => 1,
    );
    phases.record(SyncStatus.waitingForResponse);
    phases.record(SyncStatus.processing);
    phases.record(SyncStatus.cleaningUp);
    phases.record(SyncStatus.finished);
    expect(phases.metrics.snapshot()['operations'], isEmpty);
  });

  test('watchdog records status updates and disposes its account-scoped helper',
      () async {
    final target = _Target();
    var now = 0;
    final metrics = PerformanceMetrics(enabled: true);
    final phases = MatrixSyncPhaseMetrics(metrics: metrics, clockUs: () => now);
    final watchdog =
        MatrixSyncWatchdog(target: target, syncPhaseMetrics: phases);
    watchdog.start();
    target.emit(SyncStatus.waitingForResponse);
    await _settle();
    now = 10;
    target.emit(SyncStatus.processing);
    await _settle();
    now = 30;
    target.emit(SyncStatus.cleaningUp);
    await _settle();
    now = 40;
    target.emit(SyncStatus.finished);
    await _settle();
    watchdog.dispose();

    final operations = metrics.snapshot()['operations'] as Map;
    expect((operations['syncResponseWait'] as Map)['maxUs'], 10);
    expect((operations['syncProcessing'] as Map)['maxUs'], 20);
    expect((operations['syncCleanup'] as Map)['maxUs'], 10);
    target.emit(SyncStatus.waitingForResponse);
    target.emit(SyncStatus.processing);
    target.emit(SyncStatus.cleaningUp);
    target.emit(SyncStatus.finished);
    await _settle();
    final afterDispose = metrics.snapshot()['operations'] as Map;
    expect((afterDispose['syncResponseWait'] as Map)['count'], 1);
    expect((afterDispose['syncProcessing'] as Map)['count'], 1);
    expect((afterDispose['syncCleanup'] as Map)['count'], 1);
    await target.close();
  });
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

final class _Target implements SyncWatchdogTarget {
  final _updates = StreamController<SyncStatusUpdate>.broadcast();
  void emit(SyncStatus status) => _updates.add(SyncStatusUpdate(status));
  Future<void> close() => _updates.close();
  @override
  Stream<SyncStatusUpdate> get syncStatus => _updates.stream;
  @override
  Future<void> abortSync() async {}
  @override
  set backgroundSync(bool enabled) {}
  @override
  Future<void> oneShotSync() async {}
}
