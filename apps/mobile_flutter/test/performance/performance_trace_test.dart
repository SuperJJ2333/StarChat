import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';

void main() {
  late int nowUs;
  late PerformanceMetrics metrics;
  late PerformanceTraceRecorder recorder;

  setUp(() {
    nowUs = 0;
    metrics = PerformanceMetrics(enabled: true, sampleCapacity: 3);
    recorder = PerformanceTraceRecorder(metrics: metrics, clockUs: () => nowUs);
  });

  test('one random operation ID covers exact conversation stages', () {
    final trace = recorder.start(
      PerformanceOperationType.conversationOpen,
      openingSource: PerformanceOpeningSource.localRoom,
    );
    final id = trace.operationId;
    expect(id, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4')));
    trace.mark(PerformanceStage.userAction);
    nowUs = 12000;
    trace.mark(PerformanceStage.identityLookupDone);
    nowUs = 47000;
    trace.mark(PerformanceStage.localRoomLookupDone);
    nowUs = 62000;
    trace.mark(PerformanceStage.routePushStarted);
    nowUs = 92000;
    trace.mark(PerformanceStage.firstFrameRendered);
    nowUs = 130000;
    trace.mark(PerformanceStage.roomAttachDone);
    nowUs = 210000;
    trace.mark(PerformanceStage.localTimelineReady);
    nowUs = 450000;
    trace.mark(PerformanceStage.remoteSyncReady);
    final record = trace.finish();
    expect(record.operationId, id);
    expect(record.totalMs, 450);
    expect(
        record.betweenMs(
            PerformanceStage.userAction, PerformanceStage.identityLookupDone),
        12);
    expect(
        record.betweenMs(PerformanceStage.identityLookupDone,
            PerformanceStage.localRoomLookupDone),
        35);
    expect(
        record.betweenMs(PerformanceStage.routePushStarted,
            PerformanceStage.firstFrameRendered),
        30);
    expect(
        record.betweenMs(PerformanceStage.localTimelineReady,
            PerformanceStage.remoteSyncReady),
        240);
    expect(record.openingSource, PerformanceOpeningSource.localRoom);
    expect(record.toJson()['operation_id'], id);
    expect((record.toJson()['stages'] as List).length, 8);
  });

  test('finish is idempotent and an abandoned trace frees capacity', () {
    final first = recorder.start(PerformanceOperationType.conversationOpen);
    first.mark(PerformanceStage.userAction);
    nowUs = 1200;
    final a = first.finish();
    final b = first.finish();
    expect(identical(a, b), isTrue);
    expect(recorder.activeCount, 0);
    final abandoned = recorder.start(PerformanceOperationType.mediaLoad);
    expect(recorder.activeCount, 1);
    abandoned.dispose();
    abandoned.dispose();
    expect(recorder.activeCount, 0);
    expect(abandoned.isFinished, isTrue);
    expect(
        () => abandoned.mark(PerformanceStage.downloadDone), returnsNormally);
    expect((metrics.snapshot()['operations'] as Map)['mediaLoad'], isNull);
  });

  test('100 concurrent operations do not share state or exceed active cap', () {
    final traces = <PerformanceTrace>[];
    for (var i = 0; i < 100; i++) {
      traces.add(recorder.start(PerformanceOperationType.apiRequest));
    }
    expect(recorder.activeCount, 100);
    expect(traces.map((e) => e.operationId).toSet(), hasLength(100));
    final overflow = recorder.start(PerformanceOperationType.apiRequest);
    expect(recorder.activeCount, 100);
    expect(overflow.isRecording, isFalse);
    for (var i = 0; i < traces.length; i++) {
      nowUs = i * 1000;
      traces[i].mark(PerformanceStage.requestFinished);
      expect(traces[i].finish().operationId, traces[i].operationId);
    }
    expect(recorder.activeCount, 0);
    expect((metrics.snapshot()['recentTraces'] as List).length, 3);
  });

  test('frame counters are associated with a trace by measured deltas', () {
    final trace = recorder.start(PerformanceOperationType.conversationOpen);
    metrics.recordFrame(
        buildUs: 20000, rasterUs: 2000, totalUs: 22000, budgetUs: 16667);
    metrics.recordFrame(
        buildUs: 2000, rasterUs: 21000, totalUs: 23000, budgetUs: 16667);
    metrics.recordFrame(
        buildUs: 1000, rasterUs: 1000, totalUs: 2000, budgetUs: 16667);
    final record = trace.finish();
    expect(record.slowFrameCount, 2);
    expect(record.slowBuildCount, 1);
    expect(record.slowRasterCount, 1);
  });

  test('media scheduler counters and priority use bounded typed fields', () {
    final trace = recorder.start(PerformanceOperationType.mediaLoad);
    trace.setMedia(
      queued: 3,
      active: 2,
      videoActive: 1,
      priority: PerformanceMediaPriority.interactive,
    );
    final record = trace.finish();
    expect(record.schedulerQueue, 3);
    expect(record.schedulerActive, 2);
    expect(record.schedulerVideoActive, 1);
    expect(record.mediaPriority, PerformanceMediaPriority.interactive);
    expect(record.toJson()['scheduler_video_active'], 1);
    expect(record.toJson()['media_priority'], 'interactive');
  });

  test('local diagnostic snapshot includes a measured bottleneck label', () {
    final trace = recorder.start(PerformanceOperationType.conversationOpen);
    trace.mark(PerformanceStage.routePushStarted);
    nowUs = 910000;
    trace.mark(PerformanceStage.firstFrameRendered);
    trace.finish(result: PerformanceResult.slow);

    final recent = (metrics.snapshot()['recentTraces'] as List).single as Map;
    expect(recent['bottleneck'], 'client_ui');
    expect(recent['timings_ms']['navigation_ms'], 910);
  });

  test('closed fields cannot carry raw identities or message content', () {
    expect(
        () => PerformanceRecord(
              operationId: '!privateRoom:host',
              operation: PerformanceOperationType.conversationOpen,
              totalUs: 1000,
              stagesUs: const {},
              result: PerformanceResult.success,
              lifecycle: PerformanceLifecycle.foreground,
              frames: const PerformanceFrameCounts(),
            ),
        throwsArgumentError);
    final trace = recorder.start(PerformanceOperationType.conversationOpen);
    final dynamic unsafe = trace;
    expect(() => unsafe.mark('!privateRoom:host'), throwsA(isA<TypeError>()));
    trace.mark(PerformanceStage.userAction);
    final encoded = jsonEncode(trace.finish().toJson());
    for (final secret in [
      '!privateRoom:host',
      '@alice:host',
      'plaintext body',
      'Bearer token',
      'mxc://host/private',
      '192.0.2.1',
    ]) {
      expect(encoded, isNot(contains(secret)));
    }
  });

  test('lifecycle state is typed and copied into the finished record', () {
    recorder.lifecycle = PerformanceLifecycle.background;
    final background = recorder.start(PerformanceOperationType.appResume);
    expect(background.finish().lifecycle, PerformanceLifecycle.background);
    recorder.lifecycle = PerformanceLifecycle.foreground;
    final foreground =
        recorder.start(PerformanceOperationType.conversationOpen);
    expect(foreground.finish().lifecycle, PerformanceLifecycle.foreground);
  });

  test('opening source can change after local lookup without changing ID', () {
    final trace = recorder.start(PerformanceOperationType.conversationOpen);
    final id = trace.operationId;
    trace.setOpeningSource(PerformanceOpeningSource.pendingConversation);
    expect(trace.finish().openingSource,
        PerformanceOpeningSource.pendingConversation);
    expect(trace.operationId, id);
  });

  test('database metadata exposes only a closed name and coarse row bucket',
      () {
    final trace = recorder.start(PerformanceOperationType.search);
    trace.setDatabase(
        operation: PerformanceDatabaseOperation.messageSearch, rowCount: 21);
    final record = trace.finish();
    expect(
        record.databaseOperation, PerformanceDatabaseOperation.messageSearch);
    expect(record.rowCountBucket, PerformanceRowCountBucket.twentyOneToHundred);
    expect(record.toJson()['database_operation'], 'message_search');
    expect(record.toJson()['row_count_bucket'], 'twenty_one_to_hundred');
    expect(jsonEncode(record.toJson()), isNot(contains('"row_count":21')));
    final search = recorder.start(PerformanceOperationType.search);
    search.setSearchResultCount(501);
    expect(
        search.finish().toJson()['result_count_bucket'], 'over_five_hundred');
  });

  test('local diagnostic intervals use measured boundaries only', () {
    final trace = recorder.start(PerformanceOperationType.conversationOpen);
    trace.mark(PerformanceStage.userAction);
    nowUs = 12000;
    trace.mark(PerformanceStage.identityLookupDone);
    nowUs = 47000;
    trace.mark(PerformanceStage.localRoomLookupDone);
    nowUs = 62000;
    trace.mark(PerformanceStage.routePushStarted);
    nowUs = 92000;
    trace.mark(PerformanceStage.firstFrameRendered);
    nowUs = 100000;
    trace.mark(PerformanceStage.roomAttachStarted);
    nowUs = 130000;
    trace.mark(PerformanceStage.roomAttachDone);
    nowUs = 150000;
    trace.mark(PerformanceStage.timelineLocalStarted);
    nowUs = 210000;
    trace.mark(PerformanceStage.localTimelineReady);
    nowUs = 450000;
    trace.mark(PerformanceStage.remoteSyncReady);
    final record = trace.finish();
    expect(record.timingSummaryMs, {
      'conversation_open_total_ms': 450,
      'identity_lookup_ms': 12,
      'local_room_lookup_ms': 35,
      'navigation_ms': 30,
      'first_frame_ms': 92,
      'room_attach_ms': 30,
      'timeline_local_ms': 60,
      'sync_wait_ms': 240,
    });
    final local = record.toLocalDiagnosticJson();
    expect(local['timings_ms'], record.timingSummaryMs);
    expect(record.toJson(), isNot(contains('timings_ms')));
  });

  test('preconnected sync yields measured zero wait, absent sync stays null',
      () {
    final trace = recorder.start(PerformanceOperationType.conversationOpen);
    nowUs = 1000;
    trace.mark(PerformanceStage.remoteSyncReady);
    nowUs = 5000;
    trace.mark(PerformanceStage.localTimelineReady);
    final ready = trace.finish();
    expect(ready.conversationSyncWaitMs, 0);
    expect(ready.timingSummaryMs['sync_wait_ms'], 0);
    final offline = recorder.start(PerformanceOperationType.conversationOpen);
    offline.mark(PerformanceStage.localTimelineReady);
    expect(offline.finish().timingSummaryMs, isNot(contains('sync_wait_ms')));
  });

  test('video profile attempts are typed, bounded, local-only and immutable',
      () {
    final trace = recorder.start(PerformanceOperationType.videoPrepare);
    trace.mark(PerformanceStage.videoTranscodeStarted);
    trace.recordVideoTranscodeAttempt(
      profile: PerformanceVideoTranscodeProfile.normal,
      outcome: PerformanceVideoTranscodeOutcome.nativeFailure,
      duration: const Duration(milliseconds: 2300),
    );
    trace.recordVideoTranscodeAttempt(
      profile: PerformanceVideoTranscodeProfile.normal,
      outcome: PerformanceVideoTranscodeOutcome.success,
      duration: const Duration(milliseconds: 1),
    );
    trace.recordVideoTranscodeAttempt(
      profile: PerformanceVideoTranscodeProfile.aggressive,
      outcome: PerformanceVideoTranscodeOutcome.missingOutput,
      duration: const Duration(milliseconds: 900),
    );
    trace.recordVideoTranscodeAttempt(
      profile: PerformanceVideoTranscodeProfile.aggressive,
      outcome: PerformanceVideoTranscodeOutcome.success,
      duration: const Duration(milliseconds: 1),
    );
    nowUs = 4000000;
    final record = trace.finish(result: PerformanceResult.failed);
    expect(identical(record, trace.finish()), isTrue);
    expect(record.videoTranscodeAttempts, hasLength(2));
    expect(record.videoTranscodeAttempts.first.profile,
        PerformanceVideoTranscodeProfile.normal);
    expect(record.videoTranscodeAttempts.first.durationMs, 2300);
    expect(record.videoTranscodeAttempts.last.outcome,
        PerformanceVideoTranscodeOutcome.missingOutput);
    expect(() => record.videoTranscodeAttempts.clear(), throwsUnsupportedError);
    final local = record.toLocalDiagnosticJson();
    expect(local['video_transcode_attempts'], [
      {'profile': 'normal', 'outcome': 'native_failure', 'duration_ms': 2300},
      {
        'profile': 'aggressive',
        'outcome': 'missing_output',
        'duration_ms': 900
      },
    ]);
    expect(local['transcode_until_failure_ms'], 4000);
    expect(record.toJson(), isNot(contains('video_transcode_attempts')));
    expect(record.toJson(), isNot(contains('transcode_until_failure_ms')));
    final attributed = record.withFrameAttribution(
        const PerformanceFrameCounts(total: 4, slow: 2),
        complete: true);
    expect(attributed.videoTranscodeAttempts, record.videoTranscodeAttempts);
    final encoded = jsonEncode(local);
    for (final secret in [
      '!privateRoom:host',
      '@alice:host',
      'plaintext body',
      'Bearer token',
      'mxc://host/private',
      'C:\\private\\clip.mov',
    ]) {
      expect(encoded, isNot(contains(secret)));
    }
    final dynamic unsafe = trace;
    expect(
      () => unsafe.recordVideoTranscodeAttempt(
        profile: 'C:\\private\\clip.mov',
        outcome: PerformanceVideoTranscodeOutcome.success,
        duration: const Duration(seconds: 1),
      ),
      throwsA(isA<TypeError>()),
    );
  });

  test('abandoned and disabled traces do not retain video attempts', () {
    final abandoned = recorder.start(PerformanceOperationType.videoPrepare);
    abandoned.recordVideoTranscodeAttempt(
      profile: PerformanceVideoTranscodeProfile.normal,
      outcome: PerformanceVideoTranscodeOutcome.cancelled,
      duration: const Duration(seconds: 1),
    );
    abandoned.dispose();
    expect(recorder.activeCount, 0);
    final disabled = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: false),
      clockUs: () => nowUs,
    ).start(PerformanceOperationType.videoPrepare);
    disabled.recordVideoTranscodeAttempt(
      profile: PerformanceVideoTranscodeProfile.normal,
      outcome: PerformanceVideoTranscodeOutcome.nativeFailure,
      duration: const Duration(seconds: 1),
    );
    expect(disabled.finish().videoTranscodeAttempts, isEmpty);
  });
}
