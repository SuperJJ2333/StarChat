import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';
import 'package:liuhetong_mobile/features/matrix/room_navigation_coordinator.dart';

void main() {
  test('canonical room normalization preserves the same operation trace', () {
    final recorder = PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true), clockUs: () => 0);
    final trace = recorder.start(PerformanceOperationType.conversationOpen);
    final request = RoomOpenRequest(
      roomId: '!historical:test',
      roomName: 'room',
      performanceTrace: trace,
    );
    final normalized = normalizeDuplicateRoomOpen(request,
        primaryRoomIdOf: (_) => '!primary:test');
    expect(normalized.performanceTrace, same(trace));
    expect(normalized.performanceTrace!.operationId, trace.operationId);
    trace.dispose();
  });

  test('coalesced room click releases the unused new trace', () async {
    final recorder = PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true), clockUs: () => 0);
    final held = Completer<void>();
    final coordinator = RoomNavigationCoordinator(
        openRoom: (_, __) => held.future, navigatorOf: () => null);
    final first = recorder.start(PerformanceOperationType.conversationOpen);
    final second = recorder.start(PerformanceOperationType.conversationOpen);
    final opening = coordinator.open(RoomOpenRequest(
        roomId: '!same:test', roomName: 'same', performanceTrace: first));
    final coalesced = coordinator.open(RoomOpenRequest(
        roomId: '!same:test', roomName: 'same', performanceTrace: second));
    expect(coalesced, same(opening));
    expect(second.isFinished, isTrue);
    expect(first.isFinished, isFalse);
    expect(recorder.activeCount, 1);
    held.complete();
    await opening;
    first.dispose();
    coordinator.dispose();
  });
}
