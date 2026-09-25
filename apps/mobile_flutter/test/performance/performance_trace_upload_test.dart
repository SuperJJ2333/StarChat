import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/chat_diagnostics.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';

void main() {
  test('slow operation retains one ID and uploads via existing batch', () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      final diagnostics = ChatDiagnostics(
          now: () => DateTime(2026).add(time.elapsed), normalSamplePercent: 0);
      diagnostics.startSession(
        version: '0.4.6+2165',
        platform: ChatDiagnosticPlatform.android,
        upload: (batch, abort) async {
          batches.add(batch);
          return 202;
        },
      );
      final recorder = PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true),
        clockUs: () => time.elapsed.inMicroseconds,
        sessionGeneration: () => diagnostics.sessionGeneration,
        onRecord: diagnostics.recordPerformance,
      );
      final trace = recorder.start(PerformanceOperationType.conversationOpen);
      trace.mark(PerformanceStage.routePushStarted);
      time.elapse(const Duration(milliseconds: 650));
      trace.mark(PerformanceStage.firstFrameRendered);
      final record = trace.finish();
      expect(diagnostics.pendingCount, 1);
      expect(batches, isEmpty);
      time.elapse(const Duration(minutes: 1));
      expect(batches, hasLength(1));
      final json = batches.single.toJson();
      expect(json['events'], isEmpty);
      final operation = (json['operations'] as List).single as Map;
      expect(operation['operation_id'], record.operationId);
      expect(operation['operation'], 'conversation_open');
      expect(operation['total_ms'], 650);
      expect(diagnostics.pendingCount, 0);
      diagnostics.stopSession();
    });
  });

  test('video attempts reach local snapshot but never diagnostic upload', () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      final diagnostics = ChatDiagnostics(
          now: () => DateTime(2026).add(time.elapsed), normalSamplePercent: 0);
      diagnostics.startSession(
        version: '0.4.13+2179',
        platform: ChatDiagnosticPlatform.android,
        upload: (batch, abort) async {
          batches.add(batch);
          return 202;
        },
      );
      final metrics = PerformanceMetrics(enabled: true);
      final recorder = PerformanceTraceRecorder(
        metrics: metrics,
        clockUs: () => time.elapsed.inMicroseconds,
        sessionGeneration: () => diagnostics.sessionGeneration,
        onRecord: diagnostics.recordPerformance,
      );
      final trace = recorder.start(PerformanceOperationType.videoPrepare);
      trace.mark(PerformanceStage.videoTranscodeStarted);
      trace.recordVideoTranscodeAttempt(
        profile: PerformanceVideoTranscodeProfile.normal,
        outcome: PerformanceVideoTranscodeOutcome.nativeFailure,
        duration: const Duration(seconds: 2),
      );
      trace.recordVideoTranscodeAttempt(
        profile: PerformanceVideoTranscodeProfile.aggressive,
        outcome: PerformanceVideoTranscodeOutcome.cancelled,
        duration: const Duration(seconds: 1),
      );
      time.elapse(const Duration(seconds: 4));
      final record = trace.finish(result: PerformanceResult.failed);
      final local = (metrics.snapshot()['recentTraces'] as List).single as Map;
      expect(local['video_transcode_attempts'], [
        {'profile': 'normal', 'outcome': 'native_failure', 'duration_ms': 2000},
        {'profile': 'aggressive', 'outcome': 'cancelled', 'duration_ms': 1000},
      ]);
      expect(local['transcode_until_failure_ms'], 4000);
      expect(local['bottleneck'], 'media_transcode');
      expect(local['operation_id'], record.operationId);

      time.elapse(const Duration(minutes: 1));
      expect(batches, hasLength(1));
      final batch = batches.single.toJson();
      expect(batch['version'], '0.4.13+2179');
      final uploaded = (batch['operations'] as List).single as Map;
      expect(uploaded['operation_id'], record.operationId);
      expect(uploaded, isNot(contains('video_transcode_attempts')));
      expect(uploaded, isNot(contains('transcode_until_failure_ms')));
      expect(uploaded, isNot(contains('timings_ms')));
      diagnostics.stopSession();
    });
  });

  test('normal sampling is configurable; error and slow always retained', () {
    final diagnostics = ChatDiagnostics(normalSamplePercent: 0);
    diagnostics.startSession(
      version: '1.2.3',
      platform: ChatDiagnosticPlatform.ios,
      upload: (_, __) async => 202,
    );
    var now = 0;
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      clockUs: () => now,
      onRecord: diagnostics.recordPerformance,
    );
    recorder.start(PerformanceOperationType.search).finish();
    expect(diagnostics.pendingCount, 0);
    now += 2000000;
    recorder.start(PerformanceOperationType.apiRequest).finish(
        result: PerformanceResult.failed,
        networkError: PerformanceNetworkError.socketFailure);
    expect(diagnostics.pendingCount, 1);
    recorder
        .start(PerformanceOperationType.callSetup)
        .finish(result: PerformanceResult.slow);
    expect(diagnostics.pendingCount, 2);
    diagnostics.stopSession();
  });

  test('slow Matrix wait or processing retains a successful chat open', () {
    final diagnostics = ChatDiagnostics(normalSamplePercent: 0);
    diagnostics.startSession(
      version: '1.2.3',
      platform: ChatDiagnosticPlatform.android,
      upload: (_, __) async => 202,
    );
    var nowUs = 0;
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      clockUs: () => nowUs,
      onRecord: diagnostics.recordPerformance,
    );
    final waiting = recorder.start(PerformanceOperationType.conversationOpen);
    waiting.mark(PerformanceStage.userAction);
    nowUs = 20000;
    waiting.mark(PerformanceStage.routePushStarted);
    nowUs = 50000;
    waiting.mark(PerformanceStage.firstFrameRendered);
    nowUs = 100000;
    waiting.mark(PerformanceStage.localTimelineReady);
    nowUs = 2100000;
    waiting.mark(PerformanceStage.remoteSyncReady);
    waiting.finish();
    expect(diagnostics.pendingCount, 1);

    final processing =
        recorder.start(PerformanceOperationType.conversationOpen);
    processing.mark(PerformanceStage.userAction);
    nowUs = 2150000;
    processing.mark(PerformanceStage.localTimelineReady);
    processing.mark(PerformanceStage.syncResponseReceived);
    nowUs = 2850000;
    processing.mark(PerformanceStage.syncProcessingDone);
    processing.mark(PerformanceStage.remoteSyncReady);
    processing.finish();
    expect(diagnostics.pendingCount, 2);
    diagnostics.stopSession();
  });

  test('normal long-poll and healthy call use normal sampling', () {
    final diagnostics = ChatDiagnostics(normalSamplePercent: 0);
    diagnostics.startSession(
      version: '1.2.3',
      platform: ChatDiagnosticPlatform.android,
      upload: (_, __) async => 202,
    );
    var nowUs = 0;
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      clockUs: () => nowUs,
      onRecord: diagnostics.recordPerformance,
    );
    final normalSync = recorder.start(PerformanceOperationType.matrixSync);
    nowUs = 35000000;
    normalSync.mark(PerformanceStage.syncResponseReceived);
    nowUs = 35040000;
    normalSync.mark(PerformanceStage.syncProcessingDone);
    normalSync.finish();
    expect(diagnostics.pendingCount, 0);

    final healthyCall = recorder.start(PerformanceOperationType.callActive);
    healthyCall.setCallQuality(
        rttMs: 55, jitterMs: 5, packetsLost: 0, packetsReceived: 100);
    nowUs = 95000000;
    healthyCall.finish();
    expect(diagnostics.pendingCount, 0);

    final slowSync = recorder.start(PerformanceOperationType.matrixSync);
    slowSync.mark(PerformanceStage.syncResponseReceived);
    nowUs = 96000000;
    slowSync.mark(PerformanceStage.syncProcessingDone);
    slowSync.finish();
    expect(diagnostics.pendingCount, 1);

    final poorCall = recorder.start(PerformanceOperationType.callActive);
    poorCall.setCallQuality(
        rttMs: 240, jitterMs: 66, packetsLost: 7, packetsReceived: 93);
    poorCall.finish();
    expect(diagnostics.pendingCount, 2);
    diagnostics.stopSession();
  });

  test('performance queue remains bounded at 100 records', () {
    final diagnostics = ChatDiagnostics(normalSamplePercent: 100);
    diagnostics.startSession(
      version: '1.2.3',
      platform: ChatDiagnosticPlatform.ios,
      upload: (_, __) async => 202,
    );
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: false),
      enabled: () => true,
      onRecord: diagnostics.recordPerformance,
    );
    for (var i = 0; i < 120; i++) {
      recorder.start(PerformanceOperationType.search).finish();
    }
    expect(diagnostics.pendingCount, 100);
    diagnostics.stopSession();
  });

  test('a new error displaces an older normal sample at full capacity', () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      final diagnostics = ChatDiagnostics(
          now: () => DateTime(2026).add(time.elapsed),
          normalSamplePercent: 100);
      diagnostics.startSession(
        version: '1.2.3',
        platform: ChatDiagnosticPlatform.android,
        upload: (batch, abort) async {
          batches.add(batch);
          return 202;
        },
      );
      final recorder = PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: false),
        enabled: () => true,
        onRecord: diagnostics.recordPerformance,
      );
      for (var i = 0; i < 100; i++) {
        recorder.start(PerformanceOperationType.search).finish();
      }
      final error = recorder.start(PerformanceOperationType.apiRequest).finish(
          result: PerformanceResult.failed,
          networkError: PerformanceNetworkError.socketFailure);
      expect(diagnostics.pendingCount, 100);
      time.elapse(const Duration(minutes: 6));
      final uploaded = [
        for (final batch in batches)
          for (final operation
              in (batch.toJson()['operations'] as List? ?? const []))
            (operation as Map)['operation_id'],
      ];
      expect(uploaded, contains(error.operationId));
      diagnostics.stopSession();
    });
  });

  test('old server 422 drops only unsupported operation extension', () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      final diagnostics = ChatDiagnostics(
          now: () => DateTime(2026).add(time.elapsed),
          normalSamplePercent: 100);
      diagnostics.startSession(
        version: '1.2.3',
        platform: ChatDiagnosticPlatform.android,
        upload: (batch, abort) async {
          batches.add(batch);
          return batches.length == 1 ? 422 : 202;
        },
      );
      diagnostics.record(
          stage: ChatDiagnosticStage.framework,
          error: ChatDiagnosticError.unknown);
      final recorder = PerformanceTraceRecorder(
          metrics: PerformanceMetrics(enabled: false),
          enabled: () => true,
          onRecord: diagnostics.recordPerformance);
      recorder.start(PerformanceOperationType.search).finish();
      time.elapse(const Duration(minutes: 1));
      expect((batches.single.toJson()['operations'] as List), hasLength(1));
      time.elapse(const Duration(minutes: 1));
      expect(batches, hasLength(2));
      expect(batches.last.toJson().containsKey('operations'), isFalse);
      expect((batches.last.toJson()['events'] as List), hasLength(1));
      diagnostics.stopSession();
    });
  });

  test('cumulative frame counters stay monotonic across flush and reset', () {
    fakeAsync((time) {
      final diagnostics = ChatDiagnostics();
      diagnostics.startSession(
        version: '1.2.3',
        platform: ChatDiagnosticPlatform.android,
        upload: (_, __) async => 202,
      );
      diagnostics.recordFrame(buildUs: 20000, rasterUs: 1000, budgetUs: 16667);
      expect(diagnostics.cumulativeFrameCounts.slow, 1);
      time.elapse(const Duration(minutes: 1));
      expect(diagnostics.cumulativeFrameCounts.slow, 1);
      diagnostics.stopSession();
      expect(diagnostics.cumulativeFrameCounts.slow, 0);
    });
  });

  test('detailed traces are split into upload batches under the 16 KiB cap',
      () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      final diagnostics = ChatDiagnostics(
          now: () => DateTime(2026).add(time.elapsed),
          normalSamplePercent: 100);
      diagnostics.startSession(
        version: '1.2.3',
        platform: ChatDiagnosticPlatform.android,
        upload: (batch, abort) async {
          batches.add(batch);
          return utf8.encode(jsonEncode(batch.toJson())).length <= 16384
              ? 202
              : 0;
        },
      );
      final recorder = PerformanceTraceRecorder(
          metrics: PerformanceMetrics(enabled: false),
          enabled: () => true,
          onRecord: diagnostics.recordPerformance);
      final ids = <String>[];
      for (var i = 0; i < 20; i++) {
        final trace = recorder.start(PerformanceOperationType.conversationOpen);
        for (final stage in PerformanceStage.values) {
          trace.mark(stage);
        }
        ids.add(trace.finish(result: PerformanceResult.slow).operationId);
      }

      time.elapse(const Duration(minutes: 20));
      expect(batches.length, greaterThan(1));
      expect(
          batches.every((batch) =>
              utf8.encode(jsonEncode(batch.toJson())).length <= 15360),
          isTrue);
      final uploaded = [
        for (final batch in batches)
          for (final operation
              in (batch.toJson()['operations'] as List? ?? const []))
            (operation as Map)['operation_id'],
      ];
      expect(uploaded, unorderedEquals(ids));
      expect(diagnostics.pendingCount, 0);
      diagnostics.stopSession();
    });
  });

  test('an oversize head trace cannot block a later small trace', () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      final diagnostics = ChatDiagnostics(
          now: () => DateTime(2026).add(time.elapsed),
          normalSamplePercent: 100,
          maxUploadBytes: 400);
      diagnostics.startSession(
        version: '1.2.3',
        platform: ChatDiagnosticPlatform.android,
        upload: (batch, abort) async {
          batches.add(batch);
          return utf8.encode(jsonEncode(batch.toJson())).length <= 400
              ? 202
              : 0;
        },
      );
      diagnostics.recordFrame(buildUs: 20000, rasterUs: 1000, budgetUs: 16667);
      final recorder = PerformanceTraceRecorder(
          metrics: PerformanceMetrics(enabled: false),
          enabled: () => true,
          onRecord: diagnostics.recordPerformance);
      final oversize =
          recorder.start(PerformanceOperationType.conversationOpen);
      for (final stage in PerformanceStage.values) {
        oversize.mark(stage);
      }
      oversize.finish(result: PerformanceResult.slow);
      final small = recorder
          .start(PerformanceOperationType.search)
          .finish(result: PerformanceResult.failed);

      time.elapse(const Duration(minutes: 1));
      expect(batches, hasLength(1));
      final operations = batches.single.toJson()['operations'] as List;
      expect((operations.single as Map)['operation_id'], small.operationId);
      expect(diagnostics.pendingCount, 0);
      diagnostics.stopSession();
    });
  });
}
