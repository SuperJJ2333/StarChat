import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';
import 'package:liuhetong_mobile/features/matrix/room_navigation_coordinator.dart';
import 'package:liuhetong_mobile/features/matrix/room_opening_policy.dart';

void main() {
  for (final source in [
    RoomOpenSource.conversationList,
    RoomOpenSource.search,
    RoomOpenSource.notification
  ]) {
    test(
        '$source starts before association await and preserves normalized root',
        () async {
      var now = 0;
      final records = <PerformanceRecord>[];
      final recorder = PerformanceTraceRecorder(
          metrics: PerformanceMetrics(enabled: true),
          clockUs: () => now,
          onRecord: records.add);
      final prepared = Completer<void>();
      final policy =
          RoomOpeningPolicy(probe: const UnknownRoomOpenLocalProbe());
      final dynamic capable = policy;
      final pending = capable.openPrepared(
        RoomOpenRequest(roomId: '!old:test', roomName: '', source: source),
        performanceRecorder: recorder,
        prepare: () {
          expect(PerformanceTrace.currentOperation?.operation,
              PerformanceOperationType.conversationOpen);
          return prepared.future;
        },
        normalize: (RoomOpenRequest request) => normalizeDuplicateRoomOpen(
            request,
            primaryRoomIdOf: (_) => '!primary:test'),
        awaitLocalRoom: (_) async => true,
        navigate: (RoomOpenRequest request) async {
          expect(request.roomId, '!primary:test');
          expect(request.performanceTrace, isNotNull);
          expect(PerformanceTrace.currentOperation, request.performanceTrace);
          request.performanceTrace!.mark(PerformanceStage.routePushStarted);
          request.performanceTrace!.finish();
        },
      ) as Future<void>;
      expect(recorder.activeCount, 1);
      final t0 = recorder.activeObservations().single;
      expect(t0.stagesUs[PerformanceStage.userAction], 0);
      now = 350000;
      prepared.complete();
      await pending;
      expect(records.single.operationId, t0.operationId);
      expect(records.single.totalMs, 350);
    });
  }
  test(
      'association preparation failure records actual age before any navigation',
      () async {
    var now = 0;
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true),
        clockUs: () => now,
        onRecord: records.add);
    final policy = RoomOpeningPolicy(probe: const UnknownRoomOpenLocalProbe());
    await expectLater(
        (policy as dynamic).openPrepared(
            const RoomOpenRequest(
                roomId: '!room:test',
                roomName: '',
                source: RoomOpenSource.notification),
            performanceRecorder: recorder,
            prepare: () async {
              now = 210000;
              throw TimeoutException('deadline');
            },
            normalize: (RoomOpenRequest request) => request,
            navigate: (RoomOpenRequest request) async =>
                fail('must not navigate')),
        throwsA(isA<RoomOpenFailure>()));
    expect(records.single.totalMs, 210);
    expect(records.single.result, PerformanceResult.failed);
    expect(records.single.networkError, PerformanceNetworkError.requestTimeout);
    expect(records.single.stagesUs,
        isNot(contains(PerformanceStage.routePushStarted)));
  });
}
