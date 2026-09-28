import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';

void main() {
  test('semantic first frame windows do not mix unrelated page operations', () {
    var now = 0;
    final metrics = PerformanceMetrics(enabled: true, sampleCapacity: 3);
    final recorder =
        PerformanceTraceRecorder(metrics: metrics, clockUs: () => now);
    for (final operation in [
      PerformanceOperationType.walletLoad,
      PerformanceOperationType.contactsLoad,
    ]) {
      final trace = recorder.start(operation);
      trace.mark(PerformanceStage.routeEnter);
      now += operation == PerformanceOperationType.walletLoad ? 200000 : 400000;
      trace.mark(PerformanceStage.firstFrameRendered);
      trace.finish();
    }
    final summaries = metrics.snapshot()['operation_timings'] as Map?;
    expect(summaries, isNotNull);
    expect(summaries!['wallet_load']['operation']['first_frame_ms']['p95_ms'],
        200);
    expect(summaries['contacts_load']['operation']['first_frame_ms']['p95_ms'],
        400);
    recorder.clear();
  });

  test('attempt timings are bounded and do not become whole-operation totals',
      () {
    var now = 0;
    final metrics = PerformanceMetrics(enabled: true, sampleCapacity: 2);
    final recorder =
        PerformanceTraceRecorder(metrics: metrics, clockUs: () => now);
    final root = recorder.start(PerformanceOperationType.videoPrepare);
    final context = root.correlationContext;
    now = 100000;
    root.finish();
    for (var index = 0; index < 3; index++) {
      final attempt = context.startOperation(
          PerformanceOperationType.videoPrepare,
          attemptIndex: index);
      now += (index + 1) * 100000;
      attempt.finish();
    }
    final summaries = metrics.snapshot()['operation_timings'] as Map?;
    expect(summaries, isNotNull);
    final video = summaries!['video_prepare'] as Map;
    expect(video['operation']['total_ms']['count'], 1);
    expect(video['operation']['total_ms']['p95_ms'], 100);
    expect(video['attempt']['total_ms']['count'], 3);
    expect(video['attempt']['total_ms']['retained_samples'], 2);
    expect(video['attempt']['total_ms']['p50_ms'], 200);
    expect(video['attempt']['total_ms']['p99_ms'], 300);
    expect(metrics.snapshot()['sample_source'], 'complete_local_window');
    recorder.clear();
  });
}
