import 'dart:async';
import 'dart:convert';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/chat_diagnostics.dart';
import 'package:liuhetong_mobile/core/chat_diagnostics_spool_store.dart'
    show restoreDiagnosticOperation;
import 'package:liuhetong_mobile/core/performance_trace_model.dart';

class DelayedStore implements ChatDiagnosticSpoolStore {
  String? payload;
  Completer<void>? gate;
  int active = 0, maximum = 0, writes = 0;
  Future<void> wait() async {
    active++;
    if (active > maximum) maximum = active;
    try {
      await gate?.future;
    } finally {
      active--;
    }
  }

  @override
  Future<String?> read() async {
    await wait();
    return payload;
  }

  @override
  Future<void> write(String value) async {
    await wait();
    payload = value;
    writes++;
  }

  @override
  Future<void> clear() async {
    await wait();
    payload = null;
  }
}

const scopeA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const scopeB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
void main() {
  for (final failure in [0, 401, 503]) {
    test(
        'failed $failure upload restores only same account then clears durable queue',
        () {
      fakeAsync((time) {
        final store = DelayedStore();
        final batches = <ChatDiagnosticBatch>[];
        final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
        void start(int status, String scope) => d.startSession(
            version: '1.2.3',
            platform: ChatDiagnosticPlatform.android,
            upload: (b, _) async {
              batches.add(b);
              return status;
            },
            store: store,
            spoolScope: () async => scope);
        start(failure, scopeA);
        time.flushMicrotasks();
        d.record(
            stage: ChatDiagnosticStage.networkRequest,
            error: ChatDiagnosticError.timeout);
        time.elapse(const Duration(minutes: 1));
        time.flushMicrotasks();
        expect(store.payload, contains('network_request'));
        d.stopSession();
        time.flushMicrotasks();
        start(202, scopeA);
        time.flushMicrotasks();
        time.elapse(const Duration(minutes: 1));
        time.flushMicrotasks();
        expect(batches.last.toJson()['events'], hasLength(1));
        expect(d.pendingCount, 0);
        expect(store.payload, isNull);
        d.stopSession();
        time.flushMicrotasks();
      });
    });
  }
  test('slow store trailing write does not resurrect acknowledged events', () {
    fakeAsync((time) {
      final store = DelayedStore();
      final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (_, __) async => 202,
          store: store,
          spoolScope: () async => scopeA);
      time.flushMicrotasks();
      store.gate = Completer<void>();
      d.record(
          stage: ChatDiagnosticStage.matrixSend,
          error: ChatDiagnosticError.network);
      time.elapse(const Duration(seconds: 2));
      time.flushMicrotasks();
      d.record(
          stage: ChatDiagnosticStage.historyLoad,
          error: ChatDiagnosticError.timeout);
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      store.gate!.complete();
      store.gate = null;
      time.flushMicrotasks();
      expect(store.payload, isNull);
      expect(store.maximum, 1);
      d.stopSession();
      time.flushMicrotasks();
    });
  });
  test(
      'old queued I/O and delayed restore never publish into different account',
      () {
    fakeAsync((time) {
      final store = DelayedStore();
      final batches = <ChatDiagnosticBatch>[];
      final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      void start(String scope) => d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (b, _) async {
            batches.add(b);
            return 202;
          },
          store: store,
          spoolScope: () async => scope);
      start(scopeA);
      time.flushMicrotasks();
      store.gate = Completer<void>();
      d.record(
          stage: ChatDiagnosticStage.matrixSend,
          error: ChatDiagnosticError.network);
      time.elapse(const Duration(seconds: 2));
      start(scopeB);
      d.record(
          stage: ChatDiagnosticStage.historyLoad,
          error: ChatDiagnosticError.timeout);
      store.gate!.complete();
      store.gate = null;
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      expect(
          jsonEncode(batches.single.toJson()), isNot(contains('matrixSend')));
      expect(store.maximum, 1);
      d.stopSession();
      time.flushMicrotasks();
    });
  });
  test(
      'anonymous typed operations survive process restart and maintain packet counts',
      () {
    fakeAsync((time) {
      final store = DelayedStore();
      final batches = <ChatDiagnosticBatch>[];
      final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      void start(ChatDiagnostics x, int status) => x.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (b, _) async {
            batches.add(b);
            return status;
          },
          store: store,
          spoolScope: () async => scopeA);
      start(d, 401);
      time.flushMicrotasks();
      d.recordPerformance(PerformanceRecord(
          operationId: '00000000-0000-4000-8000-000000000001',
          operation: PerformanceOperationType.callActive,
          totalUs: 300000,
          stagesUs: const {},
          result: PerformanceResult.failed,
          lifecycle: PerformanceLifecycle.foreground,
          frames: const PerformanceFrameCounts(),
          packetsLost: 7,
          packetsReceived: 93,
          usesTurn: true));
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      d.stopSession();
      time.flushMicrotasks();
      final fresh =
          ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      start(fresh, 202);
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      final op = (batches.last.toJson()['operations'] as List).single as Map;
      expect(op['packet_loss_percent'], 7);
      expect(op['uses_turn'], true);
      expect(jsonEncode(batches.last.toJson()), isNot(contains(scopeA)));
      fresh.stopSession();
      time.flushMicrotasks();
    });
  });
  test('spool is byte bounded, expired or corrupt metadata rejected', () {
    fakeAsync((time) {
      final store = DelayedStore();
      final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      void start() => d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (_, __) async => 401,
          store: store,
          spoolScope: () async => scopeA);
      start();
      time.flushMicrotasks();
      for (var i = 100; i < 599; i++) {
        d.record(
            stage: ChatDiagnosticStage.networkRequest,
            error: ChatDiagnosticError.rejected,
            status: i);
      }
      time.elapse(const Duration(seconds: 2));
      time.flushMicrotasks();
      expect(utf8.encode(store.payload!).length,
          lessThanOrEqualTo(ChatDiagnostics.maxSpoolBytes));
      d.stopSession();
      time.flushMicrotasks();
      time.elapse(const Duration(days: 2));
      start();
      time.flushMicrotasks();
      expect(d.pendingCount, 0);
      d.stopSession();
      time.flushMicrotasks();
      store.payload = 'x' * (ChatDiagnostics.maxSpoolBytes + 1);
      start();
      time.flushMicrotasks();
      expect(d.pendingCount, 0);
      d.stopSession();
      time.flushMicrotasks();
    });
  });
  test(
      'same-account restore wins over a timer snapshot queued during slow old write',
      () {
    fakeAsync((time) {
      final store = DelayedStore();
      final batches = <ChatDiagnosticBatch>[];
      final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      void start() => d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (b, _) async {
            batches.add(b);
            return 202;
          },
          store: store,
          spoolScope: () async => scopeA);
      start();
      time.flushMicrotasks();
      store.gate = Completer<void>();
      d.record(
          stage: ChatDiagnosticStage.matrixSend,
          error: ChatDiagnosticError.network);
      time.elapse(const Duration(seconds: 2));
      d.stopSession();
      start();
      d.record(
          stage: ChatDiagnosticStage.historyLoad,
          error: ChatDiagnosticError.timeout);
      time.elapse(const Duration(seconds: 2));
      store.gate!.complete();
      store.gate = null;
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      final events = batches.single.toJson()['events'] as List;
      expect(events.map((e) => e['stage']),
          containsAll(['matrixSend', 'historyLoad']));
      d.stopSession();
      time.flushMicrotasks();
    });
  });
  test('corrupt persisted strings and IDs never become upload fields', () {
    fakeAsync((time) {
      final store = DelayedStore();
      final batches = <ChatDiagnosticBatch>[];
      store.payload = jsonEncode({
        'schema': 2,
        'scope': scopeA,
        'created_ms': DateTime(2026).millisecondsSinceEpoch,
        'events': [
          {
            'stage': 'roomId=PRIVATE',
            'error': 'timeout',
            'operation_id': 'token=PRIVATE'
          },
          {
            'stage': 'matrixSend',
            'error': 'network',
            'operation_id': '00000000-0000-4000-8000-000000000001',
            'count': 1,
            'elapsed_ms': 0,
            'message': 'PRIVATE'
          },
          {
            'stage': 'matrixSend',
            'error': 'network',
            'operation_id': '00000000-0000-4000-8000-000000000002',
            'count': 1,
            'elapsed_ms': 0
          }
        ],
        'operations': [
          {
            'operation': 'PRIVATE',
            'result': 'success',
            'stages': [],
            'total_ms': 1,
            'operation_id': 'PRIVATE',
            'lifecycle': 'foreground'
          }
        ]
      });
      final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (b, _) async {
            batches.add(b);
            return 202;
          },
          store: store,
          spoolScope: () async => scopeA);
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      expect(jsonEncode(batches.single.toJson()), isNot(contains('PRIVATE')));
      d.stopSession();
      time.flushMicrotasks();
    });
  });
  test(
      'fresh failure after an acknowledged 24-hour-old session remains durable',
      () {
    fakeAsync((time) {
      final store = DelayedStore();
      var status = 202;
      final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      void start() => d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (_, __) async => status,
          store: store,
          spoolScope: () async => scopeA);
      start();
      time.flushMicrotasks();
      d.record(
          stage: ChatDiagnosticStage.matrixSend,
          error: ChatDiagnosticError.network);
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      expect(store.payload, isNull);
      time.elapse(const Duration(days: 2));
      status = 401;
      d.record(
          stage: ChatDiagnosticStage.networkRequest,
          error: ChatDiagnosticError.timeout);
      time.elapse(const Duration(seconds: 2));
      time.flushMicrotasks();
      expect(store.payload, contains('network_request'));
      d.stopSession();
      time.flushMicrotasks();
      start();
      time.flushMicrotasks();
      expect(d.pendingCount, 1);
      d.stopSession();
      time.flushMicrotasks();
    });
  });
  test(
      'invalid stored frame relationships are discarded without damaging valid events',
      () {
    fakeAsync((time) {
      final store = DelayedStore();
      final batches = <ChatDiagnosticBatch>[];
      store.payload = jsonEncode({
        'schema': 2,
        'scope': scopeA,
        'created_ms': DateTime(2026).millisecondsSinceEpoch,
        'events': [
          {
            'stage': 'matrixSend',
            'error': 'network',
            'operation_id': '00000000-0000-4000-8000-000000000001',
            'count': 1,
            'elapsed_ms': 0
          }
        ],
        'frames': {
          'frame_count': 1,
          'slow_frame_count': 0,
          'slow_build_count': 1,
          'slow_raster_count': 0
        }
      });
      final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (b, _) async {
            batches.add(b);
            return 202;
          },
          store: store,
          spoolScope: () async => scopeA);
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      expect(batches.single.toJson().containsKey('frames'), false);
      expect(batches.single.toJson()['events'], hasLength(1));
      d.stopSession();
      time.flushMicrotasks();
    });
  });
  test(
      'zero counts or corrupted measured elapsed are rejected rather than repaired',
      () {
    fakeAsync((time) {
      final store = DelayedStore();
      final batches = <ChatDiagnosticBatch>[];
      store.payload = jsonEncode({
        'schema': 2,
        'scope': scopeA,
        'created_ms': DateTime(2026).millisecondsSinceEpoch,
        'events': [
          {
            'stage': 'matrixSend',
            'error': 'network',
            'operation_id': '00000000-0000-4000-8000-000000000001',
            'count': 0,
            'elapsed_ms': 0
          },
          {
            'stage': 'historyLoad',
            'error': 'network',
            'operation_id': '00000000-0000-4000-8000-000000000002',
            'count': 1,
            'elapsed_ms': 'PRIVATE'
          },
          {
            'stage': 'historySearch',
            'error': 'network',
            'operation_id': '00000000-0000-4000-8000-000000000003',
            'count': 1,
            'elapsed_ms': 20
          }
        ]
      });
      final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (b, _) async {
            batches.add(b);
            return 202;
          },
          store: store,
          spoolScope: () async => scopeA);
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      expect((batches.single.toJson()['events'] as List).single['stage'],
          'historySearch');
      d.stopSession();
      time.flushMicrotasks();
    });
  });
  test('100 maximal-stage records persist only a byte-bounded oldest prefix',
      () {
    fakeAsync((time) {
      final store = DelayedStore();
      final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (_, __) async => 401,
          store: store,
          spoolScope: () async => scopeA);
      time.flushMicrotasks();
      for (var i = 0; i < 100; i++) {
        d.recordPerformance(PerformanceRecord(
            operationId:
                '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
            operation: PerformanceOperationType.videoPrepare,
            totalUs: 3600000000,
            stagesUs: {
              for (var n = 0; n < PerformanceStage.values.length; n++)
                PerformanceStage.values[n]: n * 1000000
            },
            result: PerformanceResult.failed,
            lifecycle: PerformanceLifecycle.foreground,
            frames: const PerformanceFrameCounts()));
      }
      time.elapse(const Duration(seconds: 2));
      time.flushMicrotasks();
      final raw = store.payload!;
      expect(utf8.encode(raw).length,
          lessThanOrEqualTo(ChatDiagnostics.maxSpoolBytes));
      final ops = (jsonDecode(raw) as Map)['operations'] as List;
      expect(ops, isNotEmpty);
      expect(ops.length, lessThan(100));
      expect(ops.first['operation_id'], '00000000-0000-4000-8000-000000000000');
      expect(ops.last['operation_id'],
          '00000000-0000-4000-8000-${(ops.length - 1).toString().padLeft(12, '0')}');
      d.stopSession();
      time.flushMicrotasks();
    });
  });
  for (final evictFirst in [false, true]) {
    test(
        'held upload ACK preserves replacement after expiry eviction=$evictFirst',
        () {
      fakeAsync((time) {
        final heldUpload = Completer<int>();
        final batches = <ChatDiagnosticBatch>[];
        final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
        d.startSession(
            version: '1.2.3',
            platform: ChatDiagnosticPlatform.android,
            upload: (batch, _) {
              batches.add(batch);
              return batches.length == 1
                  ? heldUpload.future
                  : Future.value(202);
            });
        d.record(
            stage: ChatDiagnosticStage.matrixSend,
            error: ChatDiagnosticError.network);
        time.elapse(const Duration(minutes: 1));
        time.flushMicrotasks();
        final oldId =
            (batches.single.toJson()['events'] as List).single['operation_id'];
        if (evictFirst) {
          for (var i = 0; i < 99; i++) {
            d.record(
                stage: ChatDiagnosticStage.networkRequest,
                error: ChatDiagnosticError.network,
                status: 100 + i);
          }
          d.recordPerformance(PerformanceRecord(
              operationId: '00000000-0000-4000-8000-000000000001',
              operation: PerformanceOperationType.apiRequest,
              totalUs: 1000000,
              stagesUs: const {},
              result: PerformanceResult.failed,
              lifecycle: PerformanceLifecycle.foreground,
              frames: const PerformanceFrameCounts()));
          expect(d.pendingCount, 100);
        }
        time.elapse(const Duration(hours: 25));
        d.record(
            stage: ChatDiagnosticStage.matrixSend,
            error: ChatDiagnosticError.network);
        expect(d.pendingCount, 1);
        heldUpload.complete(202);
        time.flushMicrotasks();
        expect(d.pendingCount, 1);
        unawaited(d.flush());
        time.flushMicrotasks();
        final replacement =
            (batches.last.toJson()['events'] as List).single as Map;
        expect(replacement['stage'], 'matrixSend');
        expect(replacement['operation_id'], isNot(oldId));
        expect(d.pendingCount, 0);
        d.stopSession();
        time.flushMicrotasks();
      });
    });
  }
  test('held upload ACK preserves a new frame group after expiry', () {
    fakeAsync((time) {
      final heldUpload = Completer<int>();
      final batches = <ChatDiagnosticBatch>[];
      final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) {
            batches.add(batch);
            return batches.length == 1 ? heldUpload.future : Future.value(202);
          });
      d.recordFrame(buildUs: 20000, rasterUs: 1000, budgetUs: 16000);
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      expect((batches.single.toJson()['frames'] as Map)['frame_count'], 1);
      time.elapse(const Duration(hours: 25));
      d.record(
          stage: ChatDiagnosticStage.matrixSend,
          error: ChatDiagnosticError.network);
      d.recordFrame(buildUs: 1000, rasterUs: 20000, budgetUs: 16000);
      heldUpload.complete(202);
      time.flushMicrotasks();
      unawaited(d.flush());
      time.flushMicrotasks();
      expect(batches.last.toJson()['frames'], {
        'frame_count': 1,
        'slow_frame_count': 1,
        'slow_build_count': 0,
        'slow_raster_count': 1
      });
      d.stopSession();
      time.flushMicrotasks();
    });
  });
  for (final field in [
    'slow_frame_count',
    'slow_build_count',
    'slow_raster_count',
    'frames_total'
  ]) {
    for (final corruption in [null, -1, 'PRIVATE']) {
      test('complete attribution rejects $field corruption $corruption', () {
        final raw = <String, dynamic>{
          ...PerformanceRecord(
                  operationId: '00000000-0000-4000-8000-000000000001',
                  operation: PerformanceOperationType.apiRequest,
                  totalUs: 1000000,
                  stagesUs: const {},
                  result: PerformanceResult.failed,
                  lifecycle: PerformanceLifecycle.foreground,
                  frames: const PerformanceFrameCounts())
              .toJson(),
          'frames_total': 0
        };
        if (corruption == null) {
          raw.remove(field);
        } else {
          raw[field] = corruption;
        }
        expect(restoreDiagnosticOperation(raw), isNull);
      });
    }
  }
  test('422 removes only unsupported network_request preserving legacy events',
      () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      var status = 422;
      final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (b, _) async {
            batches.add(b);
            return status;
          });
      d.record(
          stage: ChatDiagnosticStage.networkRequest,
          error: ChatDiagnosticError.timeout);
      d.record(
          stage: ChatDiagnosticStage.matrixSend,
          error: ChatDiagnosticError.network);
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      status = 202;
      time.elapse(const Duration(minutes: 2));
      time.flushMicrotasks();
      expect((batches.last.toJson()['events'] as List).single['stage'],
          'matrixSend');
      d.stopSession();
    });
  });
}
