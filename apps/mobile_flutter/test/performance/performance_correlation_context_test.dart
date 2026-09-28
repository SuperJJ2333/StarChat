import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';

void main() {
  test('an explicit job context survives a failed span and correlates retry',
      () {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true), onRecord: records.add);
    final prepare = recorder.start(PerformanceOperationType.videoPrepare);
    final dynamic context = (prepare as dynamic).correlationContext;
    prepare.finish(result: PerformanceResult.failed);
    final PerformanceTrace retry = context
        .startOperation(PerformanceOperationType.videoPrepare, attemptIndex: 1);
    retry.mark(PerformanceStage.videoUploadStarted);
    retry.finish();
    expect(records, hasLength(2));
    expect(records.map((record) => record.operationId).toSet(),
        {prepare.operationId});
    expect(records.last.toJson()['attempt_index'], 1);
    recorder.clear();
  });

  test('context from an old account cannot record in a new account', () {
    var generation = 1;
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true),
        sessionGeneration: () => generation,
        onRecord: records.add);
    final prepare = recorder.start(PerformanceOperationType.videoPrepare);
    final dynamic context = (prepare as dynamic).correlationContext;
    prepare.finish();
    generation = 2;
    final PerformanceTrace late =
        context.startOperation(PerformanceOperationType.messageSend);
    expect(late.isRecording, isFalse);
    late.finish();
    expect(records, hasLength(1));
    recorder.clear();
  });

  test('releasing a job context prevents later diagnostic attempts', () {
    final recorder =
        PerformanceTraceRecorder(metrics: PerformanceMetrics(enabled: true));
    final root = recorder.start(PerformanceOperationType.videoPrepare);
    final dynamic context = (root as dynamic).correlationContext;
    context.close();
    final PerformanceTrace late =
        context.startOperation(PerformanceOperationType.videoPrepare);
    expect(late.isRecording, isFalse);
    root.dispose();
    recorder.clear();
  });
}
