import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';

void main() {
  test(
      'capacity overflow retains job identity without inventing selection time',
      () {
    var now = 0;
    var generation = 1;
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      clockUs: () => now,
      sessionGeneration: () => generation,
      activeCapacity: 1,
      onRecord: records.add,
    );
    final busy = recorder.start(PerformanceOperationType.apiRequest);
    final selection = recorder.start(PerformanceOperationType.videoPrepare);
    selection.mark(PerformanceStage.videoSelected);
    expect(selection.isRecording, isFalse);
    expect(recorder.activeCount, 1);
    expect(selection.correlationContext.isCurrent, isTrue);
    expect(
        selection.operationId, isNot('00000000-0000-4000-8000-000000000000'));
    busy.finish();
    now = 1000000;
    final prepare = selection.correlationContext
        .startOperation(PerformanceOperationType.videoPrepare, attemptIndex: 0);
    prepare.mark(PerformanceStage.videoPrepareStarted);
    now += 24000;
    prepare.mark(PerformanceStage.videoPrepareDone);
    final prepared = prepare.finish();
    expect(prepared.operationId, selection.operationId);
    expect(prepared.totalMs, 24);
    expect(
        prepared.stagesUs.containsKey(PerformanceStage.videoSelected), isFalse);
    final retry = selection.correlationContext
        .startOperation(PerformanceOperationType.messageSend, attemptIndex: 1);
    retry.mark(PerformanceStage.matrixSendStart);
    now += 7000;
    expect(retry.finish().operationId, prepared.operationId);
    expect(records, hasLength(3));
    generation++;
    expect(selection.correlationContext.isCurrent, isFalse);
    expect(
        selection.correlationContext
            .startOperation(PerformanceOperationType.messageSend)
            .isRecording,
        isFalse);
    recorder.clear();
  });

  test('disabled diagnostics never admit a job context', () {
    final recorder = PerformanceTraceRecorder(enabled: () => false);
    final selection = recorder.start(PerformanceOperationType.videoPrepare);
    expect(selection.operationId, '00000000-0000-4000-8000-000000000000');
    expect(selection.correlationContext.isCurrent, isFalse);
    expect(recorder.activeCount, 0);
    recorder.clear();
  });
  test('throwing observers do not interrupt expiry of other bounded traces',
      () {
    var now = 0;
    var observed = 0;
    final recorder = PerformanceTraceRecorder(
        enabled: () => true,
        clockUs: () => now,
        activeCapacity: 2,
        onObservation: (_) {
          observed++;
          throw StateError('private observer');
        },
        onRecord: (_) => throw StateError('private observer'));
    final first = recorder.start(PerformanceOperationType.messageSend);
    final second = recorder.start(PerformanceOperationType.messageSend);
    now = const Duration(minutes: 5).inMicroseconds;
    expect(recorder.sweepObservations, returnsNormally);
    expect(observed, 2);
    expect(recorder.activeCount, 0);
    expect(first.finish, returnsNormally);
    expect(second.finish, returnsNormally);
    recorder.clear();
  });
  test('periodic throwing observers cannot interrupt expiry or timer cleanup',
      () {
    fakeAsync((clock) {
      final recorder = PerformanceTraceRecorder(
          enabled: () => true,
          clockUs: () => clock.elapsed.inMicroseconds,
          activeCapacity: 2,
          automaticObservations: true,
          onObservation: (_) => throw StateError('private observer'));
      recorder.start(PerformanceOperationType.messageSend);
      recorder.start(PerformanceOperationType.messageSend);
      clock.elapse(const Duration(minutes: 5));
      expect(recorder.activeCount, 0);
      expect(clock.pendingTimers, isEmpty);
      recorder.clear();
    });
  });
}
