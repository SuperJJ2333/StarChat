import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';

void main() {
  test('room entry phase detail stays local for final and partial records', () {
    final stages = <PerformanceStage, int>{
      PerformanceStage.userAction: 0,
      PerformanceStage.associationPreparationStarted: 1,
      PerformanceStage.associationPreparationDone: 2,
      PerformanceStage.outboxPreparationStarted: 3,
      PerformanceStage.outboxPreparationDone: 4,
      PerformanceStage.identityLookupStarted: 5,
      PerformanceStage.roomDisplayCacheHit: 6,
      PerformanceStage.roomDisplayCacheMiss: 7,
      PerformanceStage.localTimelineSqlStarted: 8,
      PerformanceStage.localTimelineSqlDone: 9,
      PerformanceStage.roomPreparationStarted: 10,
      PerformanceStage.roomPreparationDone: 11,
    };
    final record = PerformanceRecord(
        operationId: '00000000-0000-4000-8000-000000000001',
        operation: PerformanceOperationType.conversationOpen,
        totalUs: 100,
        stagesUs: stages,
        result: PerformanceResult.success,
        lifecycle: PerformanceLifecycle.foreground,
        frames: const PerformanceFrameCounts());
    final partial = PerformanceTraceObservation(
        operationId: record.operationId,
        operation: record.operation,
        kind: PerformanceObservationKind.checkpoint,
        observedUs: 100,
        idleUs: 89,
        lifecycle: record.lifecycle,
        stagesUs: stages);
    for (final upload in [record.toJson(), partial.toJson()]) {
      expect((upload['stages'] as List).map((dynamic s) => s['stage']),
          ['user_action']);
    }
    for (final local in [
      record.toLocalDiagnosticJson(),
      partial.toLocalDiagnosticJson()
    ]) {
      expect(local['stages'], hasLength(stages.length));
    }
  });
}
