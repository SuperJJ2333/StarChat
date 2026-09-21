import 'dart:async';
import 'dart:convert';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/chat_diagnostics.dart';

void main() {
  test('late old-session failure cannot requeue or back off a new account', () {
    fakeAsync((time) {
      final diagnostics =
          ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      final old = Completer<int>();
      diagnostics.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.ios,
          upload: (_, abort) => old.future);
      diagnostics.record(
          stage: ChatDiagnosticStage.matrixSend,
          error: ChatDiagnosticError.network);
      time.elapse(const Duration(minutes: 1));
      final fresh = <ChatDiagnosticBatch>[];
      diagnostics.startSession(
          version: '1.2.4',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, abort) async {
            fresh.add(batch);
            return 202;
          });
      diagnostics.record(
          stage: ChatDiagnosticStage.historyLoad,
          error: ChatDiagnosticError.timeout);
      time.elapse(const Duration(minutes: 2));
      expect(fresh, isEmpty);
      old.complete(401);
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 1));
      expect(fresh, hasLength(1));
      expect(jsonEncode(fresh.single.toJson()), isNot(contains('matrixSend')));
      expect(diagnostics.pendingCount, 0);
      diagnostics.stopSession();
    });
  });
  test(
      'disabled until session starts; deduplicates storms and samples slow only',
      () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      final diagnostics =
          ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      diagnostics.record(
          stage: ChatDiagnosticStage.framework,
          error: ChatDiagnosticError.unknown);
      diagnostics.startSession(
          version: '0.3.103+2153',
          platform: ChatDiagnosticPlatform.ios,
          upload: (batch, abort) async {
            batches.add(batch);
            return 202;
          });
      diagnostics.record(
          stage: ChatDiagnosticStage.historyLoad,
          error: ChatDiagnosticError.slow,
          elapsed: const Duration(milliseconds: 10));
      for (var i = 0; i < 10000; i++) {
        diagnostics.record(
            stage: ChatDiagnosticStage.framework,
            error: ChatDiagnosticError.unknown);
      }
      expect(diagnostics.pendingCount, 1);
      time.elapse(const Duration(seconds: 59));
      expect(batches, isEmpty);
      time.elapse(const Duration(seconds: 1));
      expect(batches, hasLength(1));
      final json = batches.single.toJson();
      expect((json['events'] as List).single['count'], 10000);
      expect(jsonEncode(json), isNot(contains('stack')));
      expect(diagnostics.pendingCount, 0);
      diagnostics.stopSession();
    });
  });

  test('100 queued maximum, 20 each minute and no in-flight overlap', () {
    fakeAsync((time) {
      final flights = <Completer<int>>[];
      final batches = <ChatDiagnosticBatch>[];
      final diagnostics =
          ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      diagnostics.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, abort) {
            batches.add(batch);
            final flight = Completer<int>();
            flights.add(flight);
            return flight.future;
          });
      for (var status = 100; status < 300; status++) {
        diagnostics.record(
            stage: ChatDiagnosticStage.matrixSend,
            error: ChatDiagnosticError.rejected,
            status: status);
      }
      expect(diagnostics.pendingCount, 100);
      time.elapse(const Duration(minutes: 1));
      expect((batches.single.toJson()['events'] as List).length, 20);
      time.elapse(const Duration(minutes: 10));
      expect(flights, hasLength(1));
      flights.single.complete(202);
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 1));
      expect(flights, hasLength(2));
      diagnostics.stopSession();
      flights.last.complete(202);
      time.flushMicrotasks();
    });
  });

  test(
      'failure backoff capped; no recursive diagnostics; session isolation abort',
      () {
    fakeAsync((time) {
      final callTimes = <Duration>[];
      final diagnostics =
          ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      diagnostics.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.ios,
          upload: (batch, abort) async {
            callTimes.add(time.elapsed);
            throw StateError('PRIVATE_ERROR_TEXT');
          });
      diagnostics.record(
          stage: ChatDiagnosticStage.dateMonth,
          error: ChatDiagnosticError.timeout);
      time.elapse(const Duration(minutes: 61));
      expect(diagnostics.pendingCount, 1);
      expect(callTimes.take(5).map((d) => d.inMinutes), [1, 2, 4, 8, 16]);
      expect(callTimes.last - callTimes[callTimes.length - 2],
          const Duration(minutes: 15));
      diagnostics.stopSession();
      expect(diagnostics.pendingCount, 0);
      var aborted = false;
      final flight = Completer<int>();
      diagnostics.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.ios,
          upload: (batch, abort) {
            abort.then((_) => aborted = true);
            return flight.future;
          });
      diagnostics.record(
          stage: ChatDiagnosticStage.dateLocate,
          error: ChatDiagnosticError.timeout);
      time.elapse(const Duration(minutes: 1));
      diagnostics.stopSession();
      time.flushMicrotasks();
      expect(aborted, isTrue);
      expect(diagnostics.pendingCount, 0);
      flight.complete(401);
      time.flushMicrotasks();
    });
  });

  test('version pollution disables session, elapsed/count/status bounded', () {
    fakeAsync((time) {
      final diagnostics =
          ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      final batches = <ChatDiagnosticBatch>[];
      Future<int> upload(ChatDiagnosticBatch batch, Future<void> abort) async {
        batches.add(batch);
        return 202;
      }

      diagnostics.startSession(
          version: 'SECRET\nTOKEN',
          platform: ChatDiagnosticPlatform.ios,
          upload: upload);
      diagnostics.record(
          stage: ChatDiagnosticStage.framework,
          error: ChatDiagnosticError.unknown);
      time.elapse(const Duration(minutes: 1));
      expect(batches, isEmpty);
      diagnostics.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.ios,
          upload: upload);
      diagnostics.record(
          stage: ChatDiagnosticStage.framework,
          error: ChatDiagnosticError.unknown,
          elapsed: const Duration(days: 10),
          count: 999999999,
          status: 999);
      time.elapse(const Duration(minutes: 1));
      final event = (batches.single.toJson()['events'] as List).single;
      expect(event['elapsed_ms'], 3600000);
      expect(event['count'], 1000000);
      expect(event['status'], isNull);
      diagnostics.stopSession();
    });
  });
}
