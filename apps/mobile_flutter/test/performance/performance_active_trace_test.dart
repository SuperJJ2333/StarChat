import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';

void main() {
  late int nowUs;
  late PerformanceMetrics metrics;
  late PerformanceTraceRecorder recorder;
  late List<PerformanceRecord> completed;

  setUp(() {
    nowUs = 0;
    completed = [];
    metrics = PerformanceMetrics(enabled: true, sampleCapacity: 3);
    recorder = PerformanceTraceRecorder(
      metrics: metrics,
      clockUs: () => nowUs,
      onRecord: completed.add,
    );
  });

  tearDown(() => recorder.clear());

  test('a pending slow operation emits one checkpoint before expiry', () {
    final observations = <PerformanceTraceObservation>[];
    final observedRecorder = PerformanceTraceRecorder(
      metrics: metrics,
      clockUs: () => nowUs,
      onObservation: observations.add,
    );
    final trace = observedRecorder.start(PerformanceOperationType.messageSend);
    trace.mark(PerformanceStage.matrixSendStart);
    nowUs = 2000000;
    observedRecorder.sweepObservations();
    nowUs = 3000000;
    observedRecorder.sweepObservations();
    expect(observations, hasLength(1));
    expect(observations.single.kind, PerformanceObservationKind.checkpoint);
    expect(observations.single.operationId, trace.operationId);
    expect(trace.isFinished, isFalse);
    observedRecorder.clear();
  });

  test('snapshot shows measured active stage and age without finishing work',
      () {
    final trace = recorder.start(PerformanceOperationType.videoPrepare);
    trace.mark(PerformanceStage.videoPrepareStarted);
    nowUs = 12000;
    trace.mark(PerformanceStage.videoTranscodeStarted);
    nowUs = 100000;

    final active = metrics.snapshot()['active_operations'] as List?;
    expect(active, isNotNull);
    final observation = active!.single as Map;
    expect(observation['operation_id'], trace.operationId);
    expect(observation['operation'], 'video_prepare');
    expect(observation['last_stage'], 'video_transcode_started');
    expect(observation['observed_elapsed_ms'], 100);
    expect(observation['observed_idle_ms'], 88);
    expect(observation['result'], isNull);
    expect(observation['total_ms'], isNull);
    expect(observation['frame_attribution_complete'], isFalse);
    expect(completed, isEmpty);
    expect(trace.isFinished, isFalse);
  });

  test('expired observation frees capacity without changing business outcome',
      () {
    final trace = recorder.start(PerformanceOperationType.conversationOpen);
    trace.mark(PerformanceStage.userAction);
    nowUs = const Duration(seconds: 46).inMicroseconds;

    final snapshot = metrics.snapshot();
    expect(snapshot['active_operations'], isEmpty);
    expect(recorder.activeCount, 0);
    final observed = (snapshot['trace_observations'] as List?)?.single as Map?;
    expect(observed, isNotNull);
    expect(observed!['observation_kind'], 'expired');
    expect(observed['operation_id'], trace.operationId);
    expect(observed['observed_elapsed_ms'], 46000);
    expect(completed, isEmpty);
    expect(trace.isFinished, isFalse);

    nowUs += 1000;
    trace.mark(PerformanceStage.localTimelineReady);
    final finalRecord = trace.finish();
    expect(finalRecord.operationId, observed['operation_id']);
    expect(finalRecord.result, PerformanceResult.success);
    expect(finalRecord.frameAttributionComplete, isFalse);
    expect(completed, hasLength(1));
  });

  test('100 concurrent snapshots stay separate and expiration stays bounded',
      () {
    final traces = List.generate(
        100, (_) => recorder.start(PerformanceOperationType.mediaLoad));
    for (var i = 0; i < traces.length; i++) {
      nowUs = i * 1000;
      traces[i].mark(PerformanceStage.queueEntered);
    }
    final active = metrics.snapshot()['active_operations'] as List?;
    expect(active, hasLength(100));
    expect(
        active!.map((e) => (e as Map)['operation_id']).toSet(), hasLength(100));
    expect(recorder.activeCount, 100);
    nowUs = const Duration(minutes: 6).inMicroseconds;
    final expired = metrics.snapshot();
    expect(expired['active_operations'], isEmpty);
    expect(expired['trace_observations'], hasLength(3));
    expect(recorder.activeCount, 0);
    expect(
        recorder.start(PerformanceOperationType.mediaLoad).isRecording, isTrue);
  });

  test('disabled diagnostics retain no observation or additional work', () {
    final disabledMetrics = PerformanceMetrics(enabled: false);
    final disabled = PerformanceTraceRecorder(
        metrics: disabledMetrics,
        clockUs: () => nowUs,
        onRecord: completed.add);
    final trace = disabled.start(PerformanceOperationType.videoPrepare);
    trace.mark(PerformanceStage.videoTranscodeStarted);
    nowUs = const Duration(minutes: 10).inMicroseconds;
    expect(disabledMetrics.snapshot()['active_operations'], isEmpty);
    expect(disabledMetrics.snapshot()['trace_observations'], isEmpty);
    expect(disabled.activeCount, 0);
    expect(completed, isEmpty);
    trace.finish();
    expect(completed, isEmpty);
    disabled.clear();
  });
}
