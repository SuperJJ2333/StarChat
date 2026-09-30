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

  test('network request failures ride the wire as network_request events', () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      final diagnostics =
          ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      diagnostics.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) async {
            batches.add(batch);
            return 202;
          });
      diagnostics.record(
          stage: ChatDiagnosticStage.networkRequest,
          error: ChatDiagnosticError.timeout,
          count: 7);
      time.elapse(const Duration(minutes: 1));
      final event = (batches.single.toJson()['events'] as List).single as Map;
      expect(event['stage'], 'network_request');
      expect(event['error'], 'timeout');
      expect(event['count'], 7);
      diagnostics.stopSession();
    });
  });

  test('Moment failures use only closed stages and reasons on the wire', () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      final diagnostics =
          ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      diagnostics.startSession(
          version: '1.2.3+2191',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) async {
            batches.add(batch);
            return 202;
          });
      final failures = [
        (ChatDiagnosticStage.momentPrepare, ChatDiagnosticError.format),
        (ChatDiagnosticStage.momentVideoBegin, ChatDiagnosticError.timeout),
        (ChatDiagnosticStage.momentVideoPut, ChatDiagnosticError.timeout),
        (ChatDiagnosticStage.momentVideoComplete, ChatDiagnosticError.network),
        (ChatDiagnosticStage.momentPosterExtract, ChatDiagnosticError.size),
        (ChatDiagnosticStage.momentPosterBegin, ChatDiagnosticError.network),
        (ChatDiagnosticStage.momentPosterPut, ChatDiagnosticError.rejected),
        (ChatDiagnosticStage.momentPosterComplete, ChatDiagnosticError.unknown),
        (ChatDiagnosticStage.momentPublish, ChatDiagnosticError.rejected),
      ];
      for (final (stage, error) in failures) {
        diagnostics.record(
            stage: stage,
            error: error,
            elapsed: const Duration(milliseconds: 81),
            status: 504);
      }
      time.elapse(const Duration(minutes: 1));
      final json = batches.single.toJson();
      expect(json['version'], '1.2.3+2191');
      final events = json['events'] as List;
      expect(events.map((event) => (event as Map)['stage']), [
        'moment_prepare',
        'moment_video_begin',
        'moment_video_put',
        'moment_video_complete',
        'moment_poster_extract',
        'moment_poster_begin',
        'moment_poster_put',
        'moment_poster_complete',
        'moment_publish',
      ]);
      expect(events.map((event) => (event as Map)['error']), [
        'format',
        'timeout',
        'timeout',
        'network',
        'size',
        'network',
        'rejected',
        'unknown',
        'rejected'
      ]);
      for (final event in events) {
        expect((event as Map).keys.toSet(), {
          'operation_id',
          'stage',
          'error',
          'elapsed_ms',
          'count',
          'status'
        });
        expect(event['elapsed_ms'], 81);
        expect(event['status'], 504);
      }
      diagnostics.stopSession();
    });
  });

  test('Moment stages suppress nonfailure outcomes but legacy keeps them', () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      final diagnostics =
          ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      diagnostics.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) async {
            batches.add(batch);
            return 202;
          });
      for (final stage in [
        ChatDiagnosticStage.momentVideoBegin,
        ChatDiagnosticStage.momentPosterBegin,
        ChatDiagnosticStage.momentPosterPut,
      ]) {
        for (final error in [
          ChatDiagnosticError.slow,
          ChatDiagnosticError.cancelled,
          ChatDiagnosticError.incomplete,
          ChatDiagnosticError.recovered,
        ]) {
          diagnostics.record(
              stage: stage,
              error: error,
              elapsed: const Duration(milliseconds: 300));
        }
      }
      diagnostics.record(
          stage: ChatDiagnosticStage.matrixSend,
          error: ChatDiagnosticError.recovered);
      diagnostics.record(
          stage: ChatDiagnosticStage.matrixSend,
          error: ChatDiagnosticError.slow,
          elapsed: const Duration(milliseconds: 300));
      time.elapse(const Duration(minutes: 1));
      final events = batches.single.toJson()['events'] as List;
      expect(events, hasLength(2));
      expect(
          events.map((event) => event['stage']), ['matrixSend', 'matrixSend']);
      expect(events.map((event) => event['error']), ['recovered', 'slow']);
      diagnostics.stopSession();
    });
  });

  test('old receiver 422 disables only Moment extension and keeps legacy', () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      var status = 422;
      final diagnostics =
          ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      diagnostics.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) async {
            batches.add(batch);
            return status;
          });
      diagnostics.record(
          stage: ChatDiagnosticStage.momentPosterPut,
          error: ChatDiagnosticError.timeout);
      diagnostics.record(
          stage: ChatDiagnosticStage.matrixSend,
          error: ChatDiagnosticError.network);
      time.elapse(const Duration(minutes: 1));
      expect(batches, hasLength(1));
      status = 202;
      time.elapse(const Duration(minutes: 1));
      expect(batches, hasLength(2));
      expect((batches.last.toJson()['events'] as List).single['stage'],
          'matrixSend');
      expect(diagnostics.pendingCount, 0);
      diagnostics.record(
          stage: ChatDiagnosticStage.momentPosterPut,
          error: ChatDiagnosticError.timeout);
      expect(diagnostics.pendingCount, 0);
      diagnostics.stopSession();
    });
  });

  test('old receiver strips restored Moment events but retains legacy batch',
      () {
    fakeAsync((time) {
      final spool = _SpoolMemory();
      DateTime now() => DateTime.utc(2026).add(time.elapsed);
      final old = ChatDiagnostics(now: now);
      old.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (_, __) async => 401,
          store: spool,
          spoolScope: () async => List.filled(64, 'a').join());
      time.flushMicrotasks();
      old.record(
          stage: ChatDiagnosticStage.momentVideoPut,
          error: ChatDiagnosticError.timeout);
      old.record(
          stage: ChatDiagnosticStage.matrixSend,
          error: ChatDiagnosticError.network);
      time.elapse(const Duration(seconds: 2));
      time.flushMicrotasks();
      old.stopSession();
      time.flushMicrotasks();
      expect(spool.payload, contains('moment_video_put'));

      final batches = <ChatDiagnosticBatch>[];
      final restored = ChatDiagnostics(now: now);
      restored.startSession(
          version: '1.2.4',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) async {
            batches.add(batch);
            final events = batch.toJson()['events'] as List;
            return events.any((event) => event['stage'] == 'moment_video_put')
                ? 422
                : 202;
          },
          store: spool,
          spoolScope: () async => List.filled(64, 'a').join());
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 2));
      time.flushMicrotasks();
      expect(batches, hasLength(2));
      expect(batches.every((batch) => batch.version == '1.2.3'), isTrue);
      expect((batches.last.toJson()['events'] as List).single['stage'],
          'matrixSend');
      expect(restored.pendingCount, 0);
      restored.stopSession();
      time.flushMicrotasks();
    });
  });

  test('legacy diagnostic JSON retains its byte shape', () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      final diagnostics =
          ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      diagnostics.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) async {
            batches.add(batch);
            return 202;
          });
      diagnostics.record(
          stage: ChatDiagnosticStage.matrixSend,
          error: ChatDiagnosticError.network);
      time.elapse(const Duration(minutes: 1));
      final normalized = jsonEncode(batches.single.toJson()).replaceFirst(
          RegExp(
              r'[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}'),
          '<id>');
      expect(normalized,
          '{"version":"1.2.3","platform":"android","events":[{"operation_id":"<id>","stage":"matrixSend","error":"network","elapsed_ms":0,"count":1,"status":null}]}');
      diagnostics.stopSession();
    });
  });

  test('failed uploads persist pending metadata; next session backfills', () {
    fakeAsync((time) {
      final spool = _SpoolMemory();
      final diagnostics =
          ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      diagnostics.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (_, __) async => 503,
          store: spool,
          spoolScope: () async => List.filled(64, 'a').join());
      diagnostics.record(
          stage: ChatDiagnosticStage.networkRequest,
          error: ChatDiagnosticError.timeout,
          count: 2);
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      expect(spool.payload, isNotNull);
      expect(spool.payload, contains('network_request'));

      final batches = <ChatDiagnosticBatch>[];
      diagnostics.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, __) async {
            batches.add(batch);
            return 202;
          },
          store: spool,
          spoolScope: () async => List.filled(64, 'a').join());
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      expect(batches, hasLength(1));
      final restored =
          (batches.single.toJson()['events'] as List).single as Map;
      expect(restored['stage'], 'network_request');
      expect(restored['count'], 2);
      // Spool cleared once everything uploaded.
      time.flushMicrotasks();
      expect(spool.payload, isNull);
      diagnostics.stopSession();
    });
  });

  test('stopSession persists pending metadata across logout', () {
    fakeAsync((time) {
      final spool = _SpoolMemory();
      final diagnostics =
          ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      diagnostics.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.ios,
          upload: (_, __) async => 202,
          store: spool,
          spoolScope: () async => List.filled(64, 'a').join());
      diagnostics.record(
          stage: ChatDiagnosticStage.historyLoad,
          error: ChatDiagnosticError.network);
      diagnostics.stopSession();
      time.flushMicrotasks();
      expect(spool.payload, contains('historyLoad'));
    });
  });

  test('422 drops attempted events instead of poisoning later batches', () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      var status = 422;
      final diagnostics =
          ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      diagnostics.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) async {
            batches.add(batch);
            return status;
          });
      diagnostics.record(
          stage: ChatDiagnosticStage.networkRequest,
          error: ChatDiagnosticError.timeout);
      time.elapse(const Duration(minutes: 1));
      expect(batches, hasLength(1));
      status = 202;
      diagnostics.record(
          stage: ChatDiagnosticStage.matrixSend,
          error: ChatDiagnosticError.network);
      time.elapse(const Duration(minutes: 2));
      final event = (batches.last.toJson()['events'] as List).single as Map;
      expect(event['stage'], 'matrixSend');
      expect(diagnostics.pendingCount, 0);
      diagnostics.stopSession();
    });
  });
}

final class _SpoolMemory implements ChatDiagnosticSpoolStore {
  String? payload;
  @override
  Future<void> clear() async {
    payload = null;
  }

  @override
  Future<String?> read() async => payload;
  @override
  Future<void> write(String value) async {
    payload = value;
  }
}
