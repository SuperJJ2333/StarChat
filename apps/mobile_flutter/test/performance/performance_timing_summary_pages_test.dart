import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';

void main() {
  PerformanceRecord measured(
    PerformanceOperationType operation,
    List<(PerformanceStage, int)> marks,
  ) {
    var nowUs = 0;
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      clockUs: () => nowUs,
    );
    final trace = recorder.start(operation);
    for (final (stage, elapsedMs) in marks) {
      nowUs = elapsedMs * 1000;
      trace.mark(stage);
    }
    return trace.finish();
  }

  test('resume timings use real offsets from foreground trace start', () {
    final record = measured(PerformanceOperationType.appResume, [
      (PerformanceStage.firstFrameRendered, 65),
      (PerformanceStage.matrixConnected, 400),
      (PerformanceStage.syncFinished, 520),
      (PerformanceStage.conversationReady, 800),
    ]);
    expect(record.timingSummaryMs, {
      'resume_to_first_frame_ms': 65,
      'resume_to_matrix_connected_ms': 400,
      'resume_to_sync_finished_ms': 520,
      'resume_to_conversation_ready_ms': 800,
    });
    expect(
      measured(PerformanceOperationType.appResume, [
        (PerformanceStage.firstFrameRendered, 65),
      ]).timingSummaryMs,
      {'resume_to_first_frame_ms': 65},
    );
  });

  test('conversation sync phases use the same operation trace', () {
    final record = measured(PerformanceOperationType.conversationOpen, [
      (PerformanceStage.userAction, 0),
      (PerformanceStage.localTimelineReady, 80),
      (PerformanceStage.syncResponseWaitStarted, 90),
      (PerformanceStage.syncResponseReceived, 590),
      (PerformanceStage.syncProcessingDone, 630),
      (PerformanceStage.syncCleanupDone, 640),
      (PerformanceStage.remoteSyncReady, 645),
    ]);
    expect(record.timingSummaryMs['sync_wait_ms'], 565);
    expect(record.timingSummaryMs['sync_response_wait_ms'], 500);
    expect(record.timingSummaryMs['sync_processing_ms'], 40);
    expect(record.timingSummaryMs['sync_cleanup_ms'], 10);
    expect(
      measured(PerformanceOperationType.conversationOpen, [
        (PerformanceStage.userAction, 0),
        (PerformanceStage.localTimelineReady, 80),
        (PerformanceStage.syncResponseReceived, 590),
        (PerformanceStage.remoteSyncReady, 645),
      ]).timingSummaryMs,
      isNot(contains('sync_response_wait_ms')),
    );
  });

  test('wallet cache, first frame and refresh are distinct intervals', () {
    final record = measured(PerformanceOperationType.walletLoad, [
      (PerformanceStage.routeEnter, 0),
      (PerformanceStage.cacheLoadStarted, 5),
      (PerformanceStage.cacheLoadDone, 25),
      (PerformanceStage.firstFrameRendered, 70),
      (PerformanceStage.contentReady, 75),
      (PerformanceStage.remoteRefreshStarted, 90),
      (PerformanceStage.remoteRefreshDone, 490),
    ]);
    expect(record.timingSummaryMs, {
      'first_frame_ms': 70,
      'content_ready_ms': 75,
      'cache_load_ms': 20,
      'cache_to_first_frame_ms': 45,
      'remote_refresh_ms': 400,
    });
  });

  test('contacts and moments summary only measured cache and refresh', () {
    final contacts = measured(PerformanceOperationType.contactsLoad, [
      (PerformanceStage.routeEnter, 0),
      (PerformanceStage.cacheLoadStarted, 4),
      (PerformanceStage.cacheLoadDone, 18),
      (PerformanceStage.firstFrameRendered, 35),
      (PerformanceStage.contentReady, 36),
      (PerformanceStage.remoteRefreshStarted, 50),
      (PerformanceStage.remoteRefreshDone, 220),
    ]);
    expect(contacts.timingSummaryMs, {
      'first_frame_ms': 35,
      'content_ready_ms': 36,
      'cache_load_ms': 14,
      'remote_refresh_ms': 170,
    });
    final moments = measured(PerformanceOperationType.momentsLoad, [
      (PerformanceStage.routeEnter, 0),
      (PerformanceStage.cacheLoadStarted, 3),
      (PerformanceStage.firstFrameRendered, 25),
      (PerformanceStage.cacheLoadDone, 80),
      (PerformanceStage.contentReady, 83),
    ]);
    expect(moments.timingSummaryMs, {
      'first_frame_ms': 25,
      'content_ready_ms': 83,
      'cache_load_ms': 77,
    });
  });

  test('search page and query keep page render separate from local lookup', () {
    final page = measured(PerformanceOperationType.searchPageOpen, [
      (PerformanceStage.routeEnter, 0),
      (PerformanceStage.firstFrameRendered, 30),
      (PerformanceStage.contentReady, 140),
    ]);
    expect(page.timingSummaryMs, {
      'first_frame_ms': 30,
      'content_ready_ms': 140,
    });
    final query = measured(PerformanceOperationType.search, [
      (PerformanceStage.localSearchStarted, 10),
      (PerformanceStage.localSearchDone, 25),
      (PerformanceStage.renderResults, 40),
    ]);
    expect(query.timingSummaryMs, {
      'local_search_ms': 15,
      'local_search_to_render_ms': 30,
    });
    expect(query.timingSummaryMs, isNot(contains('database_search_ms')));
    expect(query.timingSummaryMs, isNot(contains('remote_search_ms')));
  });

  test('database and remote search require their own real boundaries', () {
    final record = measured(PerformanceOperationType.search, [
      (PerformanceStage.databaseSearchStarted, 2),
      (PerformanceStage.databaseSearchDone, 32),
      (PerformanceStage.remoteSearchStarted, 35),
      (PerformanceStage.remoteSearchDone, 105),
    ]);
    expect(record.timingSummaryMs, {
      'database_search_ms': 30,
      'remote_search_ms': 70,
    });
  });

  test('recent pictures keeps first frame and gallery content separate', () {
    final record = measured(PerformanceOperationType.recentPicturesLoad, [
      (PerformanceStage.routeEnter, 0),
      (PerformanceStage.firstFrameRendered, 50),
      (PerformanceStage.contentReady, 210),
    ]);
    expect(record.timingSummaryMs, {
      'first_frame_ms': 50,
      'content_ready_ms': 210,
    });
  });
}
