import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/chat_diagnostics.dart';
import 'package:liuhetong_mobile/core/chat_diagnostics_spool_store.dart';
import 'package:liuhetong_mobile/core/performance_trace_model.dart';

const rootId = '00000000-0000-4000-8000-000000000001';
const entryId = '00000000-0000-4000-8000-000000000002';
const scope =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

class MemorySpool implements ChatDiagnosticSpoolStore {
  String? payload;
  int writes = 0;
  @override
  Future<String?> read() async => payload;
  @override
  Future<void> write(String value) async {
    payload = value;
    writes++;
  }

  @override
  Future<void> clear() async => payload = null;
}

PerformanceTraceObservation observation(
        {PerformanceObservationKind kind =
            PerformanceObservationKind.checkpoint,
        PerformanceOperationType operation =
            PerformanceOperationType.messageSend,
        int? attemptIndex,
        int? windowIndex,
        int millis = 1200}) =>
    PerformanceTraceObservation(
        operationId: rootId,
        operation: operation,
        kind: kind,
        observedUs: millis * 1000,
        idleUs: (millis - 500) * 1000,
        lifecycle: PerformanceLifecycle.foreground,
        attemptIndex: attemptIndex,
        windowIndex: windowIndex,
        stagesUs: const {
          PerformanceStage.composerSubmit: 0,
          PerformanceStage.sendAdmission: 500000
        });

PerformanceRecord finalRecord(
        {PerformanceOperationType operation =
            PerformanceOperationType.messageSend,
        int? attemptIndex,
        int? windowIndex,
        PerformanceNetworkError? networkError}) =>
    PerformanceRecord(
        operationId: rootId,
        operation: operation,
        totalUs: 1500000,
        stagesUs: const {},
        result: PerformanceResult.failed,
        lifecycle: PerformanceLifecycle.foreground,
        frames: const PerformanceFrameCounts(),
        frameAttributionComplete: false,
        attemptIndex: attemptIndex,
        windowIndex: windowIndex,
        networkError: networkError);

void addObservation(ChatDiagnostics d, PerformanceTraceObservation value) =>
    d.recordObservation(value);

void main() {
  test(
      'checkpoint and expiry bypass sampling without fabricating a final result',
      () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      final d = ChatDiagnostics(
          now: () => DateTime(2026).add(time.elapsed), normalSamplePercent: 0);
      d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) async {
            batches.add(batch);
            return 202;
          });
      addObservation(d, observation());
      addObservation(d, observation(kind: PerformanceObservationKind.expired));
      expect(d.pendingCount, 2);
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      final ops = batches.single.toJson()['operations'] as List;
      expect(ops.map((v) => v['observation_kind']), ['checkpoint', 'expired']);
      for (final op in ops) {
        expect(op['operation_id'], rootId);
        expect(op['observed_elapsed_ms'], 1200);
        expect(op['frame_attribution_complete'], false);
        for (final key in [
          'result',
          'total_ms',
          'frames_total',
          'slow_frame_count',
          'packet_loss_percent',
          'observed_idle_ms',
          'last_stage',
          'queue_entry_id'
        ]) {
          expect(op, isNot(contains(key)));
        }
      }
      d.stopSession();
    });
  });

  test('observation queue is bounded and recording never performs storage IO',
      () {
    fakeAsync((time) {
      final store = MemorySpool();
      final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (_, __) async => 401,
          store: store,
          spoolScope: () async => scope);
      time.flushMicrotasks();
      for (var i = 0; i < 120; i++) {
        addObservation(d, observation());
      }
      expect(d.pendingCount, 100);
      expect(store.writes, 0);
      time.elapse(const Duration(seconds: 2));
      time.flushMicrotasks();
      expect(utf8.encode(store.payload!).length,
          lessThanOrEqualTo(ChatDiagnostics.maxSpoolBytes));
      d.stopSession();
      time.flushMicrotasks();
    });
  });

  test('same-root observation and final restore with real local idle evidence',
      () {
    fakeAsync((time) {
      final store = MemorySpool();
      void start(ChatDiagnostics d) => d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (_, __) async => 401,
          store: store,
          spoolScope: () async => scope);
      final first =
          ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      start(first);
      time.flushMicrotasks();
      addObservation(first, observation());
      addObservation(
          first, observation(kind: PerformanceObservationKind.expired));
      first.recordPerformance(finalRecord(attemptIndex: 2));
      time.elapse(const Duration(seconds: 2));
      time.flushMicrotasks();
      final before = (jsonDecode(store.payload!) as Map)['operations'] as List;
      expect(before.first['observed_idle_ms'], 700);
      first.stopSession();
      time.flushMicrotasks();
      final second =
          ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      start(second);
      time.flushMicrotasks();
      expect(second.pendingCount, 3);
      final after = (jsonDecode(store.payload!) as Map)['operations'] as List;
      expect(after.map((v) => v['queue_entry_id']),
          before.map((v) => v['queue_entry_id']));
      expect(after.first['observed_idle_ms'], 700);
      expect(after.last['attempt_index'], 2);
      second.stopSession();
      time.flushMicrotasks();
    });
  });

  test('held union ACK removes only uploaded immutable entries', () {
    fakeAsync((time) {
      final held = Completer<int>();
      final batches = <ChatDiagnosticBatch>[];
      final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) {
            batches.add(batch);
            return batches.length == 1 ? held.future : Future.value(202);
          });
      addObservation(d, observation());
      addObservation(d, observation(kind: PerformanceObservationKind.expired));
      d.recordPerformance(finalRecord());
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      expect(batches.single.toJson()['operations'], hasLength(3));
      addObservation(d, observation(millis: 2400));
      held.complete(202);
      time.flushMicrotasks();
      expect(d.pendingCount, 1);
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      expect(
          (batches.last.toJson()['operations'] as List)
              .single['observed_elapsed_ms'],
          2400);
      expect(d.pendingCount, 0);
      d.stopSession();
    });
  });

  test('422 disables partial/new fields while retaining legacy final evidence',
      () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) async {
            batches.add(batch);
            return batches.length == 1 ? 422 : 202;
          });
      addObservation(d, observation(attemptIndex: 2));
      d.recordPerformance(finalRecord(
          attemptIndex: 2,
          networkError: PerformanceNetworkError.requestTimeout));
      d.recordPerformance(
          finalRecord(operation: PerformanceOperationType.apiRequest));
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      expect(d.pendingCount, 2);
      addObservation(d, observation(kind: PerformanceObservationKind.expired));
      expect(d.pendingCount, 2);
      unawaited(d.flush());
      time.flushMicrotasks();
      expect(batches, hasLength(1),
          reason: 'compatibility keeps the 60s cadence');
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      final legacy = batches.last.toJson()['operations'] as List;
      expect(legacy, hasLength(2));
      expect(legacy.first['network_error'], 'unknown');
      expect(legacy.first, isNot(contains('attempt_index')));
      expect(legacy.first['operation_id'], rootId);
      expect(d.pendingCount, 0);
      d.recordPerformance(finalRecord(
          windowIndex: 3, operation: PerformanceOperationType.callActive));
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      expect((batches.last.toJson()['operations'] as List).single,
          isNot(contains('window_index')));
      d.stopSession();
    });
  });

  test('observation restore is a closed partial schema', () {
    final raw = <String, dynamic>{
      'queue_entry_id': entryId,
      ...observation().toJson(),
      'observed_idle_ms': 700
    };
    final restored = restoreDiagnosticQueueOperation(raw, schema: 3);
    expect(restored, isNotNull);
    final value = restored!.record as PerformanceTraceObservation;
    expect(value.idleUs, 700000);
    for (final key in [
      'result',
      'total_ms',
      'slow_frame_count',
      'frames_total',
      'packets_lost',
      'packets_received',
      'packet_loss_percent',
      'window_index',
      'roomId',
      'token',
      'message',
      'last_stage'
    ]) {
      expect(
          restoreDiagnosticQueueOperation({...raw, key: 1}, schema: 3), isNull,
          reason: key);
    }
    for (final key in ['observed_elapsed_ms', 'observed_idle_ms']) {
      for (final invalid in [-1, 3600001, 'PRIVATE', null]) {
        expect(
            restoreDiagnosticQueueOperation({...raw, key: invalid}, schema: 3),
            isNull,
            reason: '$key=$invalid');
      }
    }
    expect(
        restoreDiagnosticQueueOperation({...raw, 'observed_idle_ms': 1201},
            schema: 3),
        isNull);
    expect(
        restoreDiagnosticQueueOperation(
            {...raw, 'frame_attribution_complete': true},
            schema: 3),
        isNull);
    expect(
        restoreDiagnosticQueueOperation({...raw, 'observation_kind': 'PRIVATE'},
            schema: 3),
        isNull);
    expect(
        restoreDiagnosticQueueOperation({...raw, 'operation_id': 'PRIVATE'},
            schema: 3),
        isNull);
    expect(
        restoreDiagnosticQueueOperation({
          ...raw,
          'stages': [
            {'stage': 'composer_submit', 'elapsed_ms': 1201}
          ]
        }, schema: 3),
        isNull);
  });

  test('422 final-only optional extension preserves measured baseline fields',
      () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) async {
            batches.add(batch);
            return batches.length == 1 ? 422 : 202;
          });
      d.recordPerformance(finalRecord(
          attemptIndex: 3,
          networkError: PerformanceNetworkError.requestTimeout));
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      expect(d.pendingCount, 1);
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      final legacy =
          (batches.last.toJson()['operations'] as List).single as Map;
      expect(legacy['total_ms'], 1500);
      expect(legacy['result'], 'failed');
      expect(legacy['network_error'], 'unknown');
      expect(legacy, isNot(contains('attempt_index')));
      expect(d.pendingCount, 0);
      // Final-only incompatibility does not disable the independent observation.
      addObservation(d, observation());
      expect(d.pendingCount, 1);
      d.stopSession();
    });
  });

  test('expired union replacement survives the old snapshot ACK', () {
    fakeAsync((time) {
      final held = Completer<int>();
      final batches = <ChatDiagnosticBatch>[];
      final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) {
            batches.add(batch);
            return batches.length == 1 ? held.future : Future.value(202);
          });
      addObservation(d, observation());
      d.recordPerformance(finalRecord());
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      time.elapse(const Duration(hours: 25));
      addObservation(d, observation(kind: PerformanceObservationKind.expired));
      expect(d.pendingCount, 1);
      held.complete(202);
      time.flushMicrotasks();
      expect(d.pendingCount, 1);
      unawaited(d.flush());
      time.flushMicrotasks();
      expect(
          (batches.last.toJson()['operations'] as List)
              .single['observation_kind'],
          'expired');
      expect(d.pendingCount, 0);
      d.stopSession();
    });
  });

  test('partial parser rejects fake idle and accepts real truncation', () {
    final raw = <String, dynamic>{
      'queue_entry_id': entryId,
      ...observation().toJson(),
      'observed_idle_ms': 700
    };
    expect(
        restoreDiagnosticQueueOperation({...raw, 'observed_idle_ms': 699},
            schema: 3),
        isNotNull,
        reason: 'microsecond truncation can lose 1ms');
    expect(
        restoreDiagnosticQueueOperation({...raw, 'observed_idle_ms': 698},
            schema: 3),
        isNull);
    expect(
        restoreDiagnosticQueueOperation({...raw, 'observed_idle_ms': 701},
            schema: 3),
        isNull);
    final noIdle = Map<String, dynamic>.of(raw)..remove('observed_idle_ms');
    expect(restoreDiagnosticQueueOperation(noIdle, schema: 3), isNull);
    for (final stages in [
      [
        {'stage': 'composer_submit', 'elapsed_ms': 1},
        {'stage': 'composer_submit', 'elapsed_ms': 500}
      ],
      [
        {'stage': 'composer_submit', 'elapsed_ms': 500},
        {'stage': 'send_admission', 'elapsed_ms': 400}
      ],
      [
        {'stage': 'PRIVATE', 'elapsed_ms': 500}
      ],
      [
        {'stage': 'send_admission', 'elapsed_ms': 500, 'message': 'PRIVATE'}
      ],
      List.filled(65, {'stage': 'send_admission', 'elapsed_ms': 500})
    ]) {
      expect(
          restoreDiagnosticQueueOperation({...raw, 'stages': stages},
              schema: 3),
          isNull);
    }
    for (final field in [
      'frame_attribution_complete',
      'lifecycle',
      'observation_kind',
      'operation',
      'operation_id'
    ]) {
      final missing = Map<String, dynamic>.of(raw)..remove(field);
      expect(restoreDiagnosticQueueOperation(missing, schema: 3), isNull,
          reason: field);
    }
  });

  for (final oldStatus in [202, 401, 422]) {
    test('partial late $oldStatus cannot disable or ACK a new account', () {
      fakeAsync((time) {
        final held = Completer<int>();
        final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
        d.startSession(
            version: '1.2.3',
            platform: ChatDiagnosticPlatform.android,
            upload: (_, __) => held.future);
        addObservation(d, observation());
        time.elapse(const Duration(minutes: 1));
        time.flushMicrotasks();
        final batches = <ChatDiagnosticBatch>[];
        d.startSession(
            version: '1.2.3',
            platform: ChatDiagnosticPlatform.android,
            upload: (batch, _) async {
              batches.add(batch);
              return 202;
            });
        addObservation(
            d, observation(kind: PerformanceObservationKind.expired));
        held.complete(oldStatus);
        time.flushMicrotasks();
        expect(d.pendingCount, 1);
        time.elapse(const Duration(minutes: 1));
        time.flushMicrotasks();
        expect(
            (batches.single.toJson()['operations'] as List)
                .single['observation_kind'],
            'expired');
        expect(d.pendingCount, 0);
        d.stopSession();
      });
    });
  }

  test('attempt/window restore is range checked and operation specific', () {
    Map<String, dynamic> raw(PerformanceRecord value) =>
        {...value.toJson(), 'frames_total': 0};
    expect(
        restoreDiagnosticOperation(raw(finalRecord(attemptIndex: 20)))
            ?.attemptIndex,
        20);
    expect(
        restoreDiagnosticOperation(raw(finalRecord(
                operation: PerformanceOperationType.videoPrepare,
                attemptIndex: 0)))
            ?.attemptIndex,
        0);
    expect(
        restoreDiagnosticOperation(raw(finalRecord(
                operation: PerformanceOperationType.callActive,
                windowIndex: 1000000)))
            ?.windowIndex,
        1000000);
    final base = raw(finalRecord());
    for (final bad in [-1, 21, 'PRIVATE', null]) {
      expect(
          restoreDiagnosticOperation({...base, 'attempt_index': bad}), isNull);
    }
    final call =
        raw(finalRecord(operation: PerformanceOperationType.callActive));
    for (final bad in [-1, 1000001, 'PRIVATE', null]) {
      expect(
          restoreDiagnosticOperation({...call, 'window_index': bad}), isNull);
    }
    expect(
        restoreDiagnosticOperation(
            {...base, 'attempt_index': 1, 'window_index': 1}),
        isNull);
    expect(restoreDiagnosticOperation({...call, 'attempt_index': 1}), isNull);
    expect(restoreDiagnosticOperation({...base, 'window_index': 1}), isNull);
    expect(
        restoreDiagnosticOperation({
          ...raw(finalRecord(operation: PerformanceOperationType.apiRequest)),
          'attempt_index': 1
        }),
        isNull);
  });

  for (final (operation, field, index) in [
    ('message_send', 'attempt_index', 0),
    ('video_prepare', 'attempt_index', 20),
    ('call_active', 'window_index', 1000000),
  ]) {
    test('partial $operation preserves its $field on restore', () {
      final raw = <String, dynamic>{
        'queue_entry_id': entryId,
        ...observation().toJson(),
        'operation': operation,
        'observed_idle_ms': 700,
        field: index,
      };
      final restored = restoreDiagnosticQueueOperation(raw, schema: 3);
      expect(restored, isNotNull);
      expect(restored!.record.toJson()[field], index);
      expect(restored.record.toJson()['operation_id'], rootId);
      expect(restored.record.toJson(), isNot(contains('result')));
      expect(restored.record.toJson(), isNot(contains('total_ms')));
    });
  }

  test('partial span indexes reject wrong operations and unbounded values', () {
    final raw = <String, dynamic>{
      'queue_entry_id': entryId,
      ...observation().toJson(),
      'observed_idle_ms': 700,
    };
    for (final invalid in [-1, 21, true, 'PRIVATE', null]) {
      expect(
          restoreDiagnosticQueueOperation({...raw, 'attempt_index': invalid},
              schema: 3),
          isNull);
    }
    for (final invalid in [-1, 1000001, true, 'PRIVATE', null]) {
      expect(
          restoreDiagnosticQueueOperation(
              {...raw, 'operation': 'call_active', 'window_index': invalid},
              schema: 3),
          isNull);
    }
    for (final invalid in [
      {...raw, 'operation': 'api_request', 'attempt_index': 1},
      {...raw, 'operation': 'call_active', 'attempt_index': 1},
      {...raw, 'window_index': 1},
      {...raw, 'attempt_index': 1, 'window_index': 1},
      {...raw, 'attempt_index': 1, 'message': 'PRIVATE'},
    ]) {
      expect(restoreDiagnosticQueueOperation(invalid, schema: 3), isNull);
    }
  });

  test('same-root indexed partial and final spans survive restore and upload',
      () {
    fakeAsync((time) {
      final store = MemorySpool();
      final batches = <ChatDiagnosticBatch>[];
      final first =
          ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      first.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (_, __) async => 401,
          store: store,
          spoolScope: () async => scope);
      time.flushMicrotasks();
      first.recordObservation(observation(attemptIndex: 0));
      first.recordObservation(observation(
          attemptIndex: 1, kind: PerformanceObservationKind.expired));
      first.recordObservation(observation(
          operation: PerformanceOperationType.callActive, windowIndex: 0));
      first.recordObservation(observation(
          operation: PerformanceOperationType.callActive, windowIndex: 1));
      first.recordPerformance(finalRecord(attemptIndex: 1));
      first.recordPerformance(finalRecord(
          operation: PerformanceOperationType.callActive, windowIndex: 1));
      time.elapse(const Duration(seconds: 2));
      time.flushMicrotasks();
      first.stopSession();
      time.flushMicrotasks();
      final persisted =
          (jsonDecode(store.payload!) as Map)['operations'] as List;
      expect(persisted, hasLength(6));
      expect(persisted.map((value) => value['queue_entry_id']).toSet(),
          hasLength(6));
      final second =
          ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      second.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) async {
            batches.add(batch);
            return 202;
          },
          store: store,
          spoolScope: () async => scope);
      time.flushMicrotasks();
      expect(second.pendingCount, 6);
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      final uploaded = batches.single.toJson()['operations'] as List;
      expect(
          uploaded
              .map((value) => value['attempt_index'] ?? value['window_index']),
          [0, 1, 0, 1, 1, 1]);
      expect(
          uploaded.every((value) => value['operation_id'] == rootId), isTrue);
      expect(uploaded.every((value) => !value.containsKey('queue_entry_id')),
          isTrue);
      expect(
          uploaded.take(4).every((value) =>
              !value.containsKey('result') && !value.containsKey('total_ms')),
          isTrue);
      expect(second.pendingCount, 0);
      second.stopSession();
      time.flushMicrotasks();
    });
  });
}
