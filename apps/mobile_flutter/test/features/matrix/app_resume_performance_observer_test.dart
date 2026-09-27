import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' show SyncStatus, SyncStatusUpdate;
import 'package:liuhetong_mobile/core/performance_trace.dart';
import 'package:liuhetong_mobile/features/matrix/app_resume_performance_observer.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_sync_recovery_controller.dart';

void main() {
  test('transient inactive is not a background-to-foreground sample', () {
    expect(
        isPerformanceBackgroundTransition(AppLifecycleState.inactive), isFalse);
    expect(isPerformanceBackgroundTransition(AppLifecycleState.paused), isTrue);
    expect(isPerformanceBackgroundTransition(AppLifecycleState.hidden), isTrue);
  });
  test('resume keeps one operation ID across frame, Matrix and conversation',
      () async {
    final records = <PerformanceRecord>[];
    var tickUs = 0;
    final recorder = PerformanceTraceRecorder(
        enabled: () => true,
        clockUs: () => tickUs += 1000,
        onRecord: records.add);
    final connection = ValueNotifier(MatrixConnectionStatus.connecting);
    final sync = StreamController<SyncStatusUpdate>.broadcast(sync: true);
    addTearDown(connection.dispose);
    addTearDown(sync.close);
    void Function()? renderFrame;
    var softKicks = 4;
    var hardRestarts = 2;
    var syncErrors = 7;
    var reconnects = 3;
    final observer = AppResumePerformanceObserver(
      recorder: recorder,
      connectionStatus: connection,
      syncStatus: sync.stream,
      afterFirstFrame: (callback) => renderFrame = callback,
      conversationOpen: () => true,
      softKicks: () => softKicks,
      hardRestarts: () => hardRestarts,
      syncErrors: () => syncErrors,
      reconnects: () => reconnects,
      lastHealthySyncAge: () => const Duration(milliseconds: 1250),
    );
    addTearDown(observer.dispose);
    observer.onForeground();
    expect(records, isEmpty, reason: 'cold start is a different operation');
    observer.onBackground();
    observer.onForeground();
    renderFrame!();
    connection.value = MatrixConnectionStatus.connected;
    softKicks++;
    hardRestarts++;
    syncErrors += 2;
    reconnects++;
    sync.add(SyncStatusUpdate(SyncStatus.finished));
    expect(records, isEmpty, reason: 'active room content is still pending');
    observer.onConversationReady();
    final record = records.single;
    expect(record.operation, PerformanceOperationType.appResume);
    expect(
        record.stagesUs.keys,
        containsAll(<PerformanceStage>[
          PerformanceStage.firstFrameRendered,
          PerformanceStage.matrixConnected,
          PerformanceStage.syncFinished,
          PerformanceStage.conversationReady,
        ]));
    expect(record.softKickCount, 1);
    expect(record.hardRestartCount, 1);
    expect(record.syncErrorCount, 2);
    expect(record.reconnectCount, 1);
    expect(record.lastHealthySyncAgeMs, 1250);
    expect(record.toJson()['soft_kick_count'], 1);
    expect(record.toJson()['hard_restart_count'], 1);
    expect(record.toJson()['sync_error_count'], 2);
    expect(record.toJson()['reconnect_count'], 1);
    expect(record.toJson()['last_healthy_sync_age_ms'], 1250);
    expect(recorder.activeCount, 0);
  });

  test('background interrupts an unfinished resume without recording content',
      () async {
    final records = <PerformanceRecord>[];
    final recorder =
        PerformanceTraceRecorder(enabled: () => true, onRecord: records.add);
    final connection = ValueNotifier(MatrixConnectionStatus.unknown);
    final sync = StreamController<SyncStatusUpdate>.broadcast(sync: true);
    addTearDown(connection.dispose);
    addTearDown(sync.close);
    final observer = AppResumePerformanceObserver(
      recorder: recorder,
      connectionStatus: connection,
      syncStatus: sync.stream,
      afterFirstFrame: (_) {},
      conversationOpen: () => false,
      softKicks: () => 0,
      hardRestarts: () => 0,
    );
    observer.onBackground();
    observer.onForeground();
    expect(recorder.activeCount, 1);
    observer.onBackground();
    expect(records.single.result, PerformanceResult.cancelled);
    expect(recorder.activeCount, 0);
    observer.dispose();
  });
}
