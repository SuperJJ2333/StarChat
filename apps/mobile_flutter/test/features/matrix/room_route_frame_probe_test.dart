import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';
import 'package:liuhetong_mobile/features/matrix/room_route_frame_probe.dart';

void main() {
  test('disabled diagnostics do not leave route probe timer active', () {
    fakeAsync((time) {
      final probe =
          RoomRouteFrameProbe(PerformanceTraceRecorder(enabled: () => false));
      probe.beginEnter();
      expect(time.pendingTimers, isEmpty);
      probe.beginLeave();
      expect(time.pendingTimers, isEmpty);
      probe.dispose();
    });
  });

  test('local entry frame closes independently of remote sync', () {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      onRecord: records.add,
    );
    final probe = RoomRouteFrameProbe(recorder);
    probe.beginEnter();
    probe.onRoomFirstFrame();
    expect(records, hasLength(1));
    expect(records.single.operation, PerformanceOperationType.roomLocalFrame);
    expect(records.single.roomRoutePhase, PerformanceRoomRoutePhase.enter);
    expect(records.single.result, PerformanceResult.success);
    expect(records.single.stagesUs.keys,
        contains(PerformanceStage.roomLocalFirstFrame));
    probe.dispose();
  });

  test('leave begins at route exit and closes at next visible frame', () {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      onRecord: records.add,
    );
    final probe = RoomRouteFrameProbe(recorder);
    probe.beginEnter();
    probe.onRoomFirstFrame();
    probe.beginLeave();
    expect(records, hasLength(1));
    probe.onRouteExitFrame();
    expect(records, hasLength(2));
    expect(records.last.roomRoutePhase, PerformanceRoomRoutePhase.leave);
    expect(records.last.stagesUs.keys.toList(), [
      PerformanceStage.routeExitRequested,
      PerformanceStage.routeExitFrame,
    ]);
    probe.dispose();
  });

  test('failure cancels active entry and no late frame can revive it', () {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      onRecord: records.add,
    );
    final probe = RoomRouteFrameProbe(recorder);
    probe.beginEnter();
    probe.cancel();
    probe.onRoomFirstFrame();
    expect(records, hasLength(1));
    expect(records.single.result, PerformanceResult.cancelled);
    probe.dispose();
  });

  test('revoked route cannot begin a successful exit after entry cancel', () {
    final records = <PerformanceRecord>[];
    final probe = RoomRouteFrameProbe(PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      onRecord: records.add,
    ));
    probe.beginEnter();
    probe.invalidate();
    probe.beginLeave();
    probe.onRouteExitFrame();
    expect(records, hasLength(1));
    expect(records.single.result, PerformanceResult.cancelled);
    probe.dispose();
  });

  test('missing route frame times out as cancelled, not slow', () {
    fakeAsync((time) {
      final records = <PerformanceRecord>[];
      final recorder = PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true),
        onRecord: records.add,
      );
      final probe = RoomRouteFrameProbe(recorder);
      probe.beginLeave();
      time.elapse(const Duration(milliseconds: 1201));
      expect(records.single.result, PerformanceResult.cancelled);
      probe.onRouteExitFrame();
      expect(records, hasLength(1));
      probe.dispose();
    });
  });
}
