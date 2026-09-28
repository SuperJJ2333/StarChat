import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';
import 'package:liuhetong_mobile/features/matrix/room_keyboard_transition_probe.dart';

void main() {
  test('disabled diagnostics schedule no keyboard frames or timeout', () {
    fakeAsync((time) {
      var inset = 0.0;
      final frames = <VoidCallback>[];
      final probe = RoomKeyboardTransitionProbe(
        recorder: PerformanceTraceRecorder(enabled: () => false),
        bottomInset: () => inset,
        afterFrame: frames.add,
      );
      probe.request(PerformanceKeyboardDirection.show);
      inset = 200;
      probe.onMetricsChanged();
      expect(frames, isEmpty);
      expect(time.pendingTimers, isEmpty);
      probe.dispose();
    });
  });

  test('background metrics are ignored and resume resets inset baseline', () {
    var inset = 300.0;
    final frames = <VoidCallback>[];
    final records = <PerformanceRecord>[];
    final probe = RoomKeyboardTransitionProbe(
      recorder: PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true),
        onRecord: records.add,
      ),
      bottomInset: () => inset,
      afterFrame: frames.add,
    );
    probe.pause();
    inset = 0;
    probe.onMetricsChanged();
    expect(frames, isEmpty);
    expect(records, isEmpty);
    probe.resume();
    probe.onMetricsChanged();
    expect(frames, isEmpty,
        reason: 'insets changed while hidden are the new baseline');
    probe.request(PerformanceKeyboardDirection.show);
    inset = 300;
    probe.onMetricsChanged();
    frames.removeAt(0)();
    frames.removeAt(0)();
    expect(records.single.result, PerformanceResult.success);
    expect(records.single.keyboardDirection, PerformanceKeyboardDirection.show);
    probe.dispose();
  });

  test('show waits for two stable post-layout frames', () {
    var inset = 0.0;
    var nowUs = 0;
    final frames = <VoidCallback>[];
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      clockUs: () => nowUs,
      onRecord: records.add,
    );
    final probe = RoomKeyboardTransitionProbe(
      recorder: recorder,
      bottomInset: () => inset,
      afterFrame: frames.add,
    );
    probe.request(PerformanceKeyboardDirection.show);
    probe.request(PerformanceKeyboardDirection.show);
    inset = 288;
    nowUs = 8000;
    probe.onMetricsChanged();
    expect(frames, hasLength(1));
    frames.removeAt(0)();
    expect(records, isEmpty);
    nowUs = 16000;
    frames.removeAt(0)();
    expect(records, hasLength(1));
    expect(
        records.single.operation, PerformanceOperationType.keyboardTransition);
    expect(records.single.keyboardDirection, PerformanceKeyboardDirection.show);
    expect(records.single.result, PerformanceResult.success);
    expect(records.single.stagesUs.keys.toList(), [
      PerformanceStage.keyboardRequested,
      PerformanceStage.keyboardStableFrame,
    ]);
    probe.dispose();
  });

  test('system-back hide is measured from the first falling inset', () {
    var inset = 300.0;
    final frames = <VoidCallback>[];
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      onRecord: records.add,
    );
    final probe = RoomKeyboardTransitionProbe(
      recorder: recorder,
      bottomInset: () => inset,
      afterFrame: frames.add,
    );
    inset = 100;
    probe.onMetricsChanged();
    expect(records, isEmpty);
    inset = 0;
    probe.onMetricsChanged();
    frames.removeAt(0)();
    frames.removeAt(0)();
    expect(records.single.keyboardDirection, PerformanceKeyboardDirection.hide);
    expect(records.single.stagesUs,
        contains(PerformanceStage.keyboardStableFrame));
    probe.dispose();
  });

  test('hardware keyboard timeout is cancelled and late frames are ignored',
      () {
    fakeAsync((time) {
      var inset = 0.0;
      final frames = <VoidCallback>[];
      final records = <PerformanceRecord>[];
      final recorder = PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true),
        onRecord: records.add,
      );
      final probe = RoomKeyboardTransitionProbe(
        recorder: recorder,
        bottomInset: () => inset,
        afterFrame: frames.add,
      );
      probe.request(PerformanceKeyboardDirection.show);
      time.elapse(const Duration(milliseconds: 1201));
      expect(records.single.result, PerformanceResult.cancelled);
      inset = 200;
      probe.onMetricsChanged();
      for (final frame in List<VoidCallback>.of(frames)) {
        frame();
      }
      expect(records, hasLength(1));
      probe.dispose();
    });
  });

  test('background cancellation drops pending frame and can measure resume',
      () {
    var inset = 0.0;
    final frames = <VoidCallback>[];
    final records = <PerformanceRecord>[];
    final probe = RoomKeyboardTransitionProbe(
      recorder: PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true),
        onRecord: records.add,
      ),
      bottomInset: () => inset,
      afterFrame: frames.add,
    );
    probe.request(PerformanceKeyboardDirection.show);
    inset = 200;
    probe.onMetricsChanged();
    probe.cancel();
    frames.removeAt(0)();
    expect(records.single.result, PerformanceResult.cancelled);
    inset = 0;
    probe.request(PerformanceKeyboardDirection.show);
    inset = 220;
    probe.onMetricsChanged();
    frames.removeAt(0)();
    frames.removeAt(0)();
    expect(records, hasLength(2));
    expect(records.last.result, PerformanceResult.success);
    probe.dispose();
  });

  test('non-target inset waits for metrics instead of requesting frame loop',
      () {
    var inset = 0.0;
    final frames = <VoidCallback>[];
    final probe = RoomKeyboardTransitionProbe(
      recorder: PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true),
      ),
      bottomInset: () => inset,
      afterFrame: frames.add,
    );
    probe.request(PerformanceKeyboardDirection.show);
    inset = 0.5;
    probe.onMetricsChanged();
    frames.removeAt(0)();
    expect(frames, isEmpty,
        reason: 'a stalled keyboard must not generate frames for 1.2 seconds');
    probe.dispose();
  });

  test('opposite request cancels the old generation without losing new frames',
      () {
    var inset = 0.0;
    final frames = <VoidCallback>[];
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      onRecord: records.add,
    );
    final probe = RoomKeyboardTransitionProbe(
      recorder: recorder,
      bottomInset: () => inset,
      afterFrame: frames.add,
    );
    probe.request(PerformanceKeyboardDirection.show);
    inset = 240;
    probe.onMetricsChanged();
    probe.request(PerformanceKeyboardDirection.hide);
    inset = 0;
    probe.onMetricsChanged();
    frames.removeAt(0)(); // Stale show callback.
    frames.removeAt(0)(); // First stable hide frame.
    frames.removeAt(0)(); // Second stable hide frame.
    expect(records, hasLength(2));
    expect(records.first.result, PerformanceResult.cancelled);
    expect(records.last.result, PerformanceResult.success);
    expect(records.last.keyboardDirection, PerformanceKeyboardDirection.hide);
    probe.dispose();
  });

  test('dispose cancels the active trace and stale callbacks', () {
    var inset = 0.0;
    final frames = <VoidCallback>[];
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      onRecord: records.add,
    );
    final probe = RoomKeyboardTransitionProbe(
      recorder: recorder,
      bottomInset: () => inset,
      afterFrame: frames.add,
    );
    probe.request(PerformanceKeyboardDirection.show);
    inset = 250;
    probe.onMetricsChanged();
    probe.dispose();
    for (final frame in List<VoidCallback>.of(frames)) {
      frame();
    }
    expect(records.single.result, PerformanceResult.cancelled);
    expect(records, hasLength(1));
  });
}
