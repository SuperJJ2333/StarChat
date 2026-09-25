import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';

FrameTiming _frame({
  required int buildStartUs,
  required int buildUs,
  required int rasterFinishUs,
}) =>
    FrameTiming(
      vsyncStart: buildStartUs - 100,
      buildStart: buildStartUs,
      buildFinish: buildStartUs + buildUs,
      rasterStart: buildStartUs + buildUs,
      rasterFinish: rasterFinishUs,
      rasterFinishWallTime: rasterFinishUs,
    );

void main() {
  test('late first-frame timing is attributed after total time is frozen', () {
    var operationUs = 0;
    var frameClockUs = 100000;
    final metrics = PerformanceMetrics(enabled: true);
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: metrics,
      clockUs: () => operationUs,
      frameClockUs: () => frameClockUs,
      timestampedFrameAttribution: true,
      onRecord: records.add,
    );

    final trace = recorder.start(PerformanceOperationType.appStartup);
    operationUs = 30000;
    frameClockUs = 130000;
    trace.mark(PerformanceStage.firstFrameRendered);
    final provisional = trace.finish();
    expect(provisional.totalMs, 30);
    expect(records, isEmpty);
    expect(recorder.activeCount, 0);

    metrics.recordFrameTimingBatch([
      _frame(buildStartUs: 110000, buildUs: 19000, rasterFinishUs: 145000),
    ], budgetUs: 16667, reportedAtUs: 146000);
    expect(records, hasLength(1));
    expect(records.single.totalMs, 30);
    expect(records.single.slowFrameCount, 1);
    expect(records.single.slowBuildCount, 1);
    expect(records.single.frameAttributionComplete, isTrue);
  });

  test('frame delivered during operation but built before it is excluded', () {
    var operationUs = 0;
    var frameClockUs = 200000;
    final metrics = PerformanceMetrics(enabled: true);
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: metrics,
      clockUs: () => operationUs,
      frameClockUs: () => frameClockUs,
      timestampedFrameAttribution: true,
      onRecord: records.add,
    );
    final trace = recorder.start(PerformanceOperationType.conversationOpen);
    metrics.recordFrameTimingBatch([
      _frame(buildStartUs: 150000, buildUs: 19000, rasterFinishUs: 205000),
    ], budgetUs: 16667, reportedAtUs: 206000);
    operationUs = 20000;
    frameClockUs = 220000;
    trace.finish();
    expect(records, isEmpty);
    metrics.recordFrameTimingBatch([
      _frame(buildStartUs: 208000, buildUs: 1000, rasterFinishUs: 225000),
    ], budgetUs: 16667, reportedAtUs: 226000);
    expect(records, hasLength(1));
    expect(records.single.frames.total, 1);
    expect(records.single.slowFrameCount, 0);
    expect(metrics.frameCounts.slow, 1);
  });

  test('two recorders sharing frame metrics keep concurrent operations apart',
      () {
    var frameClockUs = 100000;
    final metrics = PerformanceMetrics(enabled: true);
    final startupRecords = <PerformanceRecord>[];
    final roomRecords = <PerformanceRecord>[];
    final startupRecorder = PerformanceTraceRecorder(
      metrics: metrics,
      frameClockUs: () => frameClockUs,
      timestampedFrameAttribution: true,
      onRecord: startupRecords.add,
    );
    final roomRecorder = PerformanceTraceRecorder(
      metrics: metrics,
      frameClockUs: () => frameClockUs,
      timestampedFrameAttribution: true,
      onRecord: roomRecords.add,
    );
    final startup = startupRecorder.start(PerformanceOperationType.appStartup);
    frameClockUs = 105000;
    final room = roomRecorder.start(PerformanceOperationType.conversationOpen);
    frameClockUs = 130000;
    startup.finish();
    room.finish();
    metrics.recordFrameTimingBatch([
      _frame(buildStartUs: 110000, buildUs: 19000, rasterFinishUs: 145000),
    ], budgetUs: 16667, reportedAtUs: 146000);
    expect(startupRecords.single.slowFrameCount, 1);
    expect(roomRecords.single.slowFrameCount, 1);
    expect(startupRecorder.pendingFrameAttributionCount, 0);
    expect(roomRecorder.pendingFrameAttributionCount, 0);
  });

  testWidgets('pending records stay bounded and logout drops later callbacks',
      (tester) async {
    var frameClockUs = 100000;
    var generation = 1;
    final metrics = PerformanceMetrics(enabled: true);
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: metrics,
      frameClockUs: () => frameClockUs,
      timestampedFrameAttribution: true,
      sessionGeneration: () => generation,
      activeCapacity: 2,
      onRecord: records.add,
    );
    for (var i = 0; i < 3; i++) {
      final trace = recorder.start(PerformanceOperationType.conversationOpen);
      frameClockUs += 1000;
      trace.finish();
    }
    expect(recorder.pendingFrameAttributionCount, 2);
    expect(records, hasLength(1));
    expect(records.single.frameAttributionComplete, isFalse);
    generation = 2;
    recorder.clear();
    metrics.recordFrameTimingBatch([
      _frame(buildStartUs: 100100, buildUs: 19000, rasterFinishUs: 145000),
    ], budgetUs: 16667, reportedAtUs: 146000);
    await tester.pump(PerformanceThresholds.frameTimingAttributionTimeout +
        const Duration(milliseconds: 1));
    expect(recorder.pendingFrameAttributionCount, 0);
    expect(records, hasLength(1));
  });

  testWidgets('uncovered end timestamp expires with unknown frame attribution',
      (tester) async {
    var frameClockUs = 100000;
    final metrics = PerformanceMetrics(enabled: true);
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: metrics,
      frameClockUs: () => frameClockUs,
      timestampedFrameAttribution: true,
      onRecord: records.add,
    );
    final trace = recorder.start(PerformanceOperationType.conversationOpen);
    frameClockUs = 130000;
    trace.finish();
    metrics.recordFrameTimingBatch([
      _frame(buildStartUs: 110000, buildUs: 19000, rasterFinishUs: 129000),
    ], budgetUs: 16667, reportedAtUs: 130000);
    expect(records, isEmpty);
    await tester.pump(PerformanceThresholds.frameTimingAttributionTimeout +
        const Duration(milliseconds: 1));
    expect(records, hasLength(1));
    expect(records.single.frameAttributionComplete, isFalse);
    expect(records.single.toJson().containsKey('slow_frame_count'), isFalse);
  });

  testWidgets('a 45 second operation retains frames beyond sample capacity',
      (tester) async {
    var frameClockUs = 100000;
    final metrics = PerformanceMetrics(enabled: true, sampleCapacity: 3);
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: metrics,
      frameClockUs: () => frameClockUs,
      timestampedFrameAttribution: true,
      onRecord: records.add,
    );
    final trace = recorder.start(PerformanceOperationType.conversationOpen);
    const operationEndUs = 45000000;
    var inWindowFrames = 0;
    for (var batch = 0; batch < 27; batch++) {
      final frames = <FrameTiming>[];
      for (var offset = 0; offset < (batch == 26 ? 90 : 100); offset++) {
        final index = batch * 100 + offset;
        final buildStartUs = 110000 + index * 16667;
        if (buildStartUs <= operationEndUs) inWindowFrames++;
        final buildUs = index == 500 || index == 2100 ? 17000 : 1000;
        frames.add(_frame(
          buildStartUs: buildStartUs,
          buildUs: buildUs,
          rasterFinishUs: buildStartUs + buildUs + 500,
        ));
      }
      frameClockUs =
          frames.last.timestampInMicroseconds(FramePhase.rasterFinish) + 1000;
      metrics.recordFrameTimingBatch(
        frames,
        budgetUs: 16667,
        reportedAtUs: frameClockUs,
      );
    }
    frameClockUs = operationEndUs;
    trace.finish();
    metrics.recordFrameTimingBatch([
      _frame(
        buildStartUs: operationEndUs - 1000,
        buildUs: 1000,
        rasterFinishUs: operationEndUs + 1000,
      ),
    ], budgetUs: 16667, reportedAtUs: operationEndUs + 2000);
    inWindowFrames++;
    await tester.pump(PerformanceThresholds.frameTimingAttributionTimeout +
        const Duration(milliseconds: 1));
    expect(records, hasLength(1));
    expect(records.single.frameAttributionComplete, isTrue);
    expect(records.single.frames.total, inWindowFrames);
    expect(records.single.slowFrameCount, 2);
  });

  test('different callback and trace clocks leave frame count unknown', () {
    var frameClockUs = 100000;
    final metrics = PerformanceMetrics(enabled: true);
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: metrics,
      frameClockUs: () => frameClockUs,
      timestampedFrameAttribution: true,
      onRecord: records.add,
    );
    final trace = recorder.start(PerformanceOperationType.conversationOpen);
    frameClockUs = 130000;
    trace.finish();
    metrics.recordFrameTimingBatch([
      _frame(buildStartUs: 110000, buildUs: 19000, rasterFinishUs: 145000),
    ], budgetUs: 16667, reportedAtUs: 9000000);
    expect(records, hasLength(1));
    expect(records.single.frameAttributionComplete, isFalse);
    expect(records.single.toJson().containsKey('slow_frame_count'), isFalse);
  });
}
