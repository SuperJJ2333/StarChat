import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_sync_phase_metrics.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_sync_watchdog.dart';
import 'package:matrix/matrix.dart'
    show
        SyncStatus,
        SyncStatusUpdate,
        SdkError,
        SyncConnectionException,
        MatrixException;

void main() {
  for (final sample in <(Object, PerformanceNetworkError, int?)>[
    (
      SyncConnectionException(TimeoutException('PRIVATE')),
      PerformanceNetworkError.requestTimeout,
      null
    ),
    (
      const HandshakeException('PRIVATE'),
      PerformanceNetworkError.tlsFailure,
      null
    ),
    (
      MatrixException(
          http.Response('{"errcode":"M_UNKNOWN","error":"PRIVATE"}', 429)),
      PerformanceNetworkError.rateLimit,
      429
    ),
    (
      MatrixException(http.Response(
          '{"errcode":"M_UNKNOWN_TOKEN","error":"PRIVATE"}', 401)),
      PerformanceNetworkError.authFailure,
      401
    ),
    (
      MatrixException(
          http.Response('{"errcode":"M_FORBIDDEN","error":"PRIVATE"}', 403)),
      PerformanceNetworkError.authFailure,
      403
    ),
    (
      MatrixException(
          http.Response('{"errcode":"M_UNKNOWN","error":"PRIVATE"}', 503)),
      PerformanceNetworkError.server5xx,
      503
    ),
    (
      MatrixException(
          http.Response('{"errcode":"M_UNKNOWN","error":"PRIVATE"}', 400)),
      PerformanceNetworkError.businessRejection,
      400
    ),
    (StateError('PRIVATE processing'), PerformanceNetworkError.unknown, null),
  ]) {
    test(
        'sync failure ${sample.$2.name} ${sample.$3} keeps only closed error facts',
        () {
      final records = <PerformanceRecord>[];
      final metrics = PerformanceMetrics(enabled: true);
      final recorder =
          PerformanceTraceRecorder(metrics: metrics, onRecord: records.add);
      final phases =
          MatrixSyncPhaseMetrics(metrics: metrics, traceRecorder: recorder);
      phases.record(SyncStatus.error, error: SdkError(exception: sample.$1));
      expect(records.single.networkError, sample.$2);
      expect(records.single.statusCode, sample.$3);
      expect(records.single.stagesUs, isEmpty);
      expect(jsonEncode(records.single.toJson()), isNot(contains('PRIVATE')));
      phases.dispose();
      recorder.clear();
    });
  }
  test('normal 35s long polling has no slow checkpoint or asserted bottleneck',
      () {
    var now = 0;
    final records = <PerformanceRecord>[];
    final partial = <PerformanceTraceObservation>[];
    final metrics = PerformanceMetrics(enabled: true);
    final recorder = PerformanceTraceRecorder(
        metrics: metrics,
        clockUs: () => now,
        onRecord: records.add,
        onObservation: partial.add);
    final phases = MatrixSyncPhaseMetrics(
        metrics: metrics, clockUs: () => now, traceRecorder: recorder);
    phases.record(SyncStatus.waitingForResponse);
    now = 35000000;
    recorder.sweepObservations();
    expect(partial, isEmpty);
    phases.record(SyncStatus.processing);
    now += 40000;
    phases.record(SyncStatus.cleaningUp);
    now += 10000;
    phases.record(SyncStatus.finished);
    expect(records.single.stagesUs[PerformanceStage.syncResponseReceived],
        35000000);
    expect(PerformanceBottleneckClassifier.classify(records.single),
        PerformanceBottleneck.unknown);
    phases.dispose();
  });

  test('watchdog preserves real SDK timeout without inventing transport loss',
      () async {
    var now = 0;
    final records = <PerformanceRecord>[];
    final metrics = PerformanceMetrics(enabled: true);
    final recorder = PerformanceTraceRecorder(
        metrics: metrics, clockUs: () => now, onRecord: records.add);
    final phases = MatrixSyncPhaseMetrics(
        metrics: metrics, clockUs: () => now, traceRecorder: recorder);
    final target = _Target();
    final watchdog =
        MatrixSyncWatchdog(target: target, syncPhaseMetrics: phases);
    watchdog.start();
    target.emit(SyncStatus.waitingForResponse);
    await _settle();
    now = 2000000;
    target.emit(SyncStatus.error,
        error: TimeoutException('PRIVATE 192.0.2.3 token=PRIVATE'));
    await _settle();
    expect(records.single.networkError, PerformanceNetworkError.requestTimeout);
    expect(records.single.syncErrorCount, 1);
    expect(watchdog.transportAvailable.value, isNull);
    expect(jsonEncode(records.single.toJson()), isNot(contains('PRIVATE')));
    expect(jsonEncode(records.single.toJson()), isNot(contains('192.0.2.3')));
    watchdog.dispose();
    await target.close();
  });

  test('SDK socket error without waiting retains only actual error evidence',
      () async {
    final records = <PerformanceRecord>[];
    final metrics = PerformanceMetrics(enabled: true);
    final recorder =
        PerformanceTraceRecorder(metrics: metrics, onRecord: records.add);
    final phases =
        MatrixSyncPhaseMetrics(metrics: metrics, traceRecorder: recorder);
    final target = _Target();
    final watchdog =
        MatrixSyncWatchdog(target: target, syncPhaseMetrics: phases);
    watchdog.start();
    target.emit(SyncStatus.error,
        error: const SocketException('PRIVATE 192.0.2.4'));
    await _settle();
    expect(records, hasLength(1));
    expect(records.single.result, PerformanceResult.failed);
    expect(records.single.networkError, PerformanceNetworkError.socketFailure);
    expect(records.single.stagesUs, isEmpty);
    expect(watchdog.transportAvailable.value, isNull);
    watchdog.dispose();
    await target.close();
  });

  test('watchdog counter deltas belong only to their real sync cycle',
      () async {
    var nowUs = 0;
    var now = DateTime.utc(2026, 9, 26);
    final records = <PerformanceRecord>[];
    final metrics = PerformanceMetrics(enabled: true);
    final recorder = PerformanceTraceRecorder(
        metrics: metrics, clockUs: () => nowUs, onRecord: records.add);
    final phases = MatrixSyncPhaseMetrics(
        metrics: metrics, clockUs: () => nowUs, traceRecorder: recorder);
    final target = _Target();
    final watchdog = MatrixSyncWatchdog(
        target: target, syncPhaseMetrics: phases, clock: () => now);
    watchdog.start();
    target.emit(SyncStatus.finished); // A real previous healthy SDK cycle.
    await _settle();
    target.emit(SyncStatus.waitingForResponse);
    await _settle();
    now = now.add(const Duration(minutes: 3));
    nowUs += 180000000;
    await watchdog.tick();
    await _settle();
    now = now.add(const Duration(minutes: 3));
    nowUs += 180000000;
    await watchdog.tick();
    await _settle();
    target.emit(SyncStatus.error, error: TimeoutException('private'));
    await _settle();
    expect(records.single.softKickCount, 1);
    expect(records.single.hardRestartCount, 1);
    expect(records.single.syncErrorCount, 1);
    expect(records.single.reconnectCount, 0);
    expect(records.single.lastHealthySyncAgeMs, 360000);
    for (var cycle = 0; cycle < 2; cycle++) {
      target.emit(SyncStatus.waitingForResponse);
      await _settle();
      nowUs += 100000;
      target.emit(SyncStatus.processing);
      await _settle();
      nowUs += 40000;
      target.emit(SyncStatus.cleaningUp);
      await _settle();
      nowUs += 10000;
      target.emit(SyncStatus.finished);
      await _settle();
      expect(records.last.softKickCount, 0);
      expect(records.last.hardRestartCount, 0);
      expect(records.last.syncErrorCount, 0);
      expect(records.last.reconnectCount, cycle == 0 ? 1 : 0);
      expect(records.last.lastHealthySyncAgeMs, 0);
    }
    expect(records.map((r) => r.operationId).toSet(), hasLength(3));
    watchdog.dispose();
    recorder.clear();
    await target.close();
  });

  test('one completed sync cycle shares a trace ID across real stages', () {
    var now = 100;
    final metrics = PerformanceMetrics(enabled: true);
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: metrics,
      clockUs: () => now,
      onRecord: records.add,
    );
    final phases = MatrixSyncPhaseMetrics(
      metrics: metrics,
      clockUs: () => now,
      traceRecorder: recorder,
    );

    phases.record(SyncStatus.waitingForResponse);
    now = 500;
    phases.record(SyncStatus.processing);
    now = 700;
    phases.record(SyncStatus.processing);
    now = 900;
    phases.record(SyncStatus.cleaningUp);
    now = 1200;
    phases.record(SyncStatus.finished);

    expect(records, hasLength(1));
    final record = records.single;
    expect(record.operation, PerformanceOperationType.matrixSync);
    expect(record.totalUs, 1100);
    expect(record.stagesUs, {
      PerformanceStage.syncResponseReceived: 400,
      PerformanceStage.syncProcessingDone: 800,
      PerformanceStage.syncCleanupDone: 1100,
    });
    expect(record.operationId, isNotEmpty);
    expect(recorder.activeCount, 0);
    final operations = metrics.snapshot()['operations'] as Map;
    expect((operations['syncResponseWait'] as Map)['maxUs'], 400);
    expect((operations['syncProcessing'] as Map)['maxUs'], 400);
    expect((operations['syncCleanup'] as Map)['maxUs'], 300);
    expect((operations['syncCycleTotal'] as Map)['maxUs'], 1100);
  });

  test('sync error closes partial trace and next cycle gets a new ID', () {
    var now = 0;
    final metrics = PerformanceMetrics(enabled: false);
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: metrics,
      enabled: () => true,
      clockUs: () => now,
      onRecord: records.add,
    );
    final phases = MatrixSyncPhaseMetrics(
      metrics: metrics,
      clockUs: () => throw StateError('legacy clock must remain unused'),
      traceRecorder: recorder,
    );

    phases.record(SyncStatus.waitingForResponse);
    now = 10;
    phases.record(SyncStatus.processing);
    now = 20;
    phases.record(SyncStatus.error);
    expect(recorder.activeCount, 0);
    expect(records.single.result, PerformanceResult.failed);
    expect(records.single.stagesUs,
        contains(PerformanceStage.syncResponseReceived));

    now = 30;
    phases.record(SyncStatus.waitingForResponse);
    now = 40;
    phases.record(SyncStatus.processing);
    now = 50;
    phases.record(SyncStatus.cleaningUp);
    now = 60;
    phases.record(SyncStatus.finished);
    expect(records, hasLength(2));
    expect(records.last.result, PerformanceResult.success);
    expect(records.last.operationId, isNot(records.first.operationId));
    expect(recorder.activeCount, 0);
    expect(metrics.snapshot()['operations'], isEmpty);
  });

  test('disabled sync diagnostics never read either timing clock', () {
    var legacyClockCalls = 0;
    var traceClockCalls = 0;
    final metrics = PerformanceMetrics(enabled: false);
    final recorder = PerformanceTraceRecorder(
      metrics: metrics,
      enabled: () => false,
      clockUs: () {
        traceClockCalls++;
        return 0;
      },
    );
    final phases = MatrixSyncPhaseMetrics(
      metrics: metrics,
      clockUs: () {
        legacyClockCalls++;
        return 0;
      },
      traceRecorder: recorder,
    );
    phases.record(SyncStatus.waitingForResponse);
    phases.record(SyncStatus.processing);
    phases.record(SyncStatus.cleaningUp);
    phases.record(SyncStatus.finished);
    expect(legacyClockCalls, 0);
    expect(traceClockCalls, 0);
    expect(recorder.activeCount, 0);
  });

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
    expect((operations['syncCycleTotal'] as Map)['maxUs'], 1100);
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
  void emit(SyncStatus status, {Object? error}) =>
      _updates.add(SyncStatusUpdate(status,
          error: error == null ? null : SdkError(exception: error)));
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
