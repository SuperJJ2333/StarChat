import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/chat_diagnostics.dart';

void main() {
  void frame(ChatDiagnostics d, int build, int raster, {int budget = 16667}) =>
      d.recordFrame(buildUs: build, rasterUs: raster, budgetUs: budget);

  test('bounded whole-frame sampling survives transport failure', () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) async {
            batches.add(batch);
            return batches.length == 1 ? 503 : 202;
          });
      for (var i = 0; i < 1000000; i++) {
        frame(d, 1, 1);
      }
      // Reject the entire sample at capacity, never count a partial numerator.
      frame(d, 20000, 20000);
      time.elapse(const Duration(minutes: 2));
      expect(batches, hasLength(2));
      expect(batches.first.toJson()['frames'], batches.last.toJson()['frames']);
      expect(batches.last.toJson()['frames'], {
        'frame_count': 1000000,
        'slow_frame_count': 0,
        'slow_build_count': 0,
        'slow_raster_count': 0,
      });
      d.stopSession();
    });
  });

  test('budget union counts once, exact boundary passes, invalid input ignored',
      () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      frame(d, 20000, 20000);
      d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (b, _) async {
            batches.add(b);
            return 202;
          });
      frame(d, 16667, 16667);
      frame(d, 20000, 20000);
      frame(d, 9000, 1000, budget: 8333);
      frame(d, 1000, 9000, budget: 8333);
      frame(d, -1, 5);
      frame(d, 1, 1, budget: 0);
      time.elapse(const Duration(minutes: 1));
      expect(batches.single.toJson()['frames'], {
        'frame_count': 4,
        'slow_frame_count': 3,
        'slow_build_count': 2,
        'slow_raster_count': 2,
      });
      expect(batches.single.toJson()['events'], isEmpty);
      time.elapse(const Duration(minutes: 1));
      expect(batches, hasLength(1));
      d.stopSession();
    });
  });

  test('successful flight subtracts snapshot and preserves new frame counts',
      () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      final flights = <Completer<int>>[];
      final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.ios,
          upload: (b, _) {
            batches.add(b);
            final f = Completer<int>();
            flights.add(f);
            return f.future;
          });
      frame(d, 20000, 1000);
      time.elapse(const Duration(minutes: 1));
      frame(d, 1000, 20000);
      flights.first.complete(202);
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 1));
      expect(batches.last.toJson()['frames'], {
        'frame_count': 1,
        'slow_frame_count': 1,
        'slow_build_count': 0,
        'slow_raster_count': 1,
      });
      flights.last.complete(202);
      time.flushMicrotasks();
      d.stopSession();
    });
  });

  test('old server rejects frames once, existing events retry without frames',
      () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.ios,
          upload: (b, _) async {
            batches.add(b);
            return batches.length == 1 ? 422 : 202;
          });
      frame(d, 20000, 20000);
      d.record(
          stage: ChatDiagnosticStage.framework,
          error: ChatDiagnosticError.unknown);
      time.elapse(const Duration(minutes: 1));
      frame(d, 20000, 20000);
      time.elapse(const Duration(minutes: 1));
      expect(batches, hasLength(2));
      expect(batches.last.toJson().containsKey('frames'), isFalse);
      expect(batches.last.toJson()['events'], hasLength(1));
      d.stopSession();
    });
  });

  test(
      'account switch clears frame counters and stale result cannot erase new counts',
      () {
    fakeAsync((time) {
      final old = Completer<int>();
      final batches = <ChatDiagnosticBatch>[];
      final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.ios,
          upload: (_, abort) => old.future);
      frame(d, 20000, 20000);
      time.elapse(const Duration(minutes: 1));
      d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.ios,
          upload: (b, _) async {
            batches.add(b);
            return 202;
          });
      frame(d, 1, 1);
      old.complete(422);
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 1));
      expect(batches.single.toJson()['frames'], {
        'frame_count': 1,
        'slow_frame_count': 0,
        'slow_build_count': 0,
        'slow_raster_count': 0,
      });
      d.stopSession();
    });
  });
}
