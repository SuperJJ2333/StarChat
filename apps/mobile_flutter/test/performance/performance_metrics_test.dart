import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';

void main() {
  test('invalid capacities are rejected at runtime', () {
    for (final capacity in [0, -1]) {
      expect(() => PerformanceMetrics(enabled: true, sampleCapacity: capacity),
          throwsArgumentError);
    }
  });
  test('disabled telemetry keeps no samples or counters', () {
    final metrics = PerformanceMetrics(enabled: false);
    metrics.record(PerformanceOperation.timelineRefresh, 123);
    metrics.increment(PerformanceCounter.mediaMemoryHit);
    expect(metrics.snapshot()['operations'], isEmpty);
    expect(metrics.snapshot()['counters'], isEmpty);
  });
  test(
      'samples bounded per operation and percentiles represent retained window',
      () {
    final metrics = PerformanceMetrics(enabled: true, sampleCapacity: 3);
    for (final micros in [1000, 10, 20, 30]) {
      metrics.record(PerformanceOperation.timelineRefresh, micros);
    }
    final operation =
        (metrics.snapshot()['operations'] as Map)['timelineRefresh'] as Map;
    expect(operation['count'], 4);
    expect(operation['retainedSamples'], 3);
    expect(operation['p50Us'], 20);
    expect(operation['p95Us'], 30);
    metrics.reset();
    expect(metrics.snapshot()['operations'], isEmpty);
  });
  test(
      'frame stage overload is measured separately from pipeline total latency',
      () {
    final metrics = PerformanceMetrics(enabled: true);
    metrics.recordFrame(
        buildUs: 5000, rasterUs: 5000, totalUs: 24000, budgetUs: 16667);
    metrics.recordFrame(
        buildUs: 18000, rasterUs: 2000, totalUs: 28000, budgetUs: 16667);
    final counters = metrics.snapshot()['counters'] as Map;
    expect(counters['frames'], 2);
    expect(counters['slowBuildFrames'], 1);
    expect(counters['slowRasterFrames'] ?? 0, 0);
    // This is not an actual display deadline/dropped-frame claim.
    expect(counters.containsKey('droppedFrames'), isFalse);
  });
}
