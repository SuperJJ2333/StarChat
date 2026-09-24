import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/chat_diagnostics.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';
import 'package:liuhetong_mobile/main.dart' as app;

void main() {
  testWidgets('app startup trace finishes once after the first Flutter frame',
      (tester) async {
    var nowUs = 0;
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      clockUs: () => nowUs,
      onRecord: records.add,
    );

    final trace = app.scheduleAppStartupFirstFrame(recorder: recorder);
    expect(trace, isNotNull);
    expect(records, isEmpty);
    expect(recorder.activeCount, 1);

    nowUs = 240000;
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: Text('startup'),
    ));

    expect(records, hasLength(1));
    expect(records.single.operation, PerformanceOperationType.appStartup);
    expect(records.single.operationId, trace!.operationId);
    expect(records.single.totalMs, 240);
    expect(records.single.stagesUs.keys,
        contains(PerformanceStage.firstFrameRendered));
    expect(records.single.stagesUs.keys,
        isNot(contains(PerformanceStage.contentReady)));
    expect(recorder.activeCount, 0);

    await tester.pump();
    expect(records, hasLength(1));
  });

  testWidgets('disabled startup diagnostics schedule no record or clock read',
      (tester) async {
    var clockReads = 0;
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: false),
      clockUs: () {
        clockReads++;
        return 0;
      },
      onRecord: records.add,
    );

    final trace = app.scheduleAppStartupFirstFrame(recorder: recorder);
    final localMetrics = PerformanceMetrics(enabled: false);
    final localTrace =
        app.scheduleAppStartupFirstFrame(localMetrics: localMetrics);
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: Text('startup'),
    ));

    expect(trace, isNull);
    expect(localTrace, isNull);
    expect(clockReads, 0);
    expect(records, isEmpty);
    expect(recorder.activeCount, 0);
    expect(localMetrics.snapshot()['recentTraces'], isEmpty);
  });

  testWidgets('local startup record survives a diagnostics session change',
      (tester) async {
    final metrics = PerformanceMetrics(enabled: true);
    final trace = app.scheduleAppStartupFirstFrame(localMetrics: metrics);
    expect(trace, isNotNull);
    ChatDiagnostics.instance.stopSession();

    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: Text('startup'),
    ));

    final recent = metrics.snapshot()['recentTraces'] as List<Object?>;
    expect(recent, hasLength(1));
    final record = recent.single as Map<String, Object?>;
    expect(record['operation_id'], trace!.operationId);
    expect(record['operation'], 'app_startup');
    expect(ChatDiagnostics.instance.pendingCount, 0);
  });
}
