import 'dart:async';
import 'dart:convert';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/chat_diagnostics.dart';
import 'package:liuhetong_mobile/core/chat_diagnostics_spool_store.dart'
    show restoreDiagnosticOperation;
import 'package:liuhetong_mobile/core/diagnostic_time_anchor.dart';
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

PerformanceRecord sameRootRecord(int millis,
        {PerformanceOperationType operation =
            PerformanceOperationType.apiRequest}) =>
    PerformanceRecord(
        operationId: '00000000-0000-4000-8000-000000000001',
        operation: operation,
        totalUs: millis * 1000,
        stagesUs: const {},
        result: PerformanceResult.failed,
        lifecycle: PerformanceLifecycle.foreground,
        frames: const PerformanceFrameCounts(),
        frameAttributionComplete: false);

void main() {
  test('spool preserves bounded sync and closed UI operation fields', () {
    final sync = PerformanceRecord(
      operationId: '00000000-0000-4000-8000-000000000001',
      operation: PerformanceOperationType.matrixSync,
      totalUs: 100000,
      stagesUs: const {},
      result: PerformanceResult.success,
      lifecycle: PerformanceLifecycle.foreground,
      frames: const PerformanceFrameCounts(),
      timelineEventCount: 14,
      utcWindow: const DiagnosticUtcWindow(
        startedAtUtc: '2026-09-28T08:00:00Z',
        endedAtUtc: '2026-09-28T08:00:00.100Z',
        clockUncertaintyMs: 1000,
        timeAnchorAgeMs: 1000,
      ),
    );
    final restoredSync = restoreDiagnosticOperation({
      ...sync.toJson(),
      'frames_total': 0,
    });
    expect(restoredSync?.toJson()['timeline_event_count'], 14);
    expect(restoredSync?.toJson()['started_at_utc'], '2026-09-28T08:00:00Z');
    expect(
        restoreDiagnosticOperation({
          ...sync.toJson(),
          'frames_total': 0,
          'started_at_utc': '2026-09-28T16:00:00+08:00',
        }),
        isNull);
    expect(
      restoreDiagnosticOperation({
        ...sync.toJson(),
        'frames_total': 0,
        'timeline_event_count': 100001,
      }),
      isNull,
    );

    final keyboard = PerformanceRecord(
      operationId: '00000000-0000-4000-8000-000000000002',
      operation: PerformanceOperationType.keyboardTransition,
      totalUs: 20000,
      stagesUs: const {},
      result: PerformanceResult.success,
      lifecycle: PerformanceLifecycle.foreground,
      frames: const PerformanceFrameCounts(),
      keyboardDirection: PerformanceKeyboardDirection.hide,
    );
    expect(
      restoreDiagnosticOperation({...keyboard.toJson(), 'frames_total': 0})
          ?.toJson()['keyboard_direction'],
      'hide',
    );
  });

  test('older receiver retries legacy operation and drops new-only UI kind',
      () {
    fakeAsync((time) {
      final attempts = <Map<String, Object?>>[];
      final diagnostics = ChatDiagnostics(
        now: () => DateTime.utc(2026).add(time.elapsed),
      );
      diagnostics.startSession(
        version: '1.2.4',
        platform: ChatDiagnosticPlatform.android,
        upload: (batch, _) async {
          final json = batch.toJson();
          attempts.add(json);
          final ops = json['operations'] as List? ?? const [];
          return ops.any((op) =>
                  op['operation'] == 'history_search' ||
                  op.containsKey('timeline_event_count'))
              ? 422
              : 202;
        },
      );
      diagnostics.recordPerformance(PerformanceRecord(
        operationId: '00000000-0000-4000-8000-000000000001',
        operation: PerformanceOperationType.historySearch,
        totalUs: 20000,
        stagesUs: const {},
        result: PerformanceResult.failed,
        lifecycle: PerformanceLifecycle.foreground,
        frames: const PerformanceFrameCounts(),
      ));
      diagnostics.recordPerformance(PerformanceRecord(
        operationId: '00000000-0000-4000-8000-000000000002',
        operation: PerformanceOperationType.matrixSync,
        totalUs: 30000,
        stagesUs: const {},
        result: PerformanceResult.failed,
        lifecycle: PerformanceLifecycle.foreground,
        frames: const PerformanceFrameCounts(),
        timelineEventCount: 8,
      ));
      diagnostics.recordPerformance(PerformanceRecord(
        operationId: '00000000-0000-4000-8000-000000000003',
        operation: PerformanceOperationType.apiRequest,
        totalUs: 40000,
        stagesUs: const {},
        result: PerformanceResult.failed,
        lifecycle: PerformanceLifecycle.foreground,
        frames: const PerformanceFrameCounts(),
        utcWindow: const DiagnosticUtcWindow(
          startedAtUtc: '2026-09-28T08:00:00Z',
          endedAtUtc: '2026-09-28T08:00:00.040Z',
          clockUncertaintyMs: 1000,
          timeAnchorAgeMs: 1000,
        ),
      ));
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      expect(attempts, hasLength(2));
      final retry = attempts.last['operations'] as List;
      expect(
          retry.map((op) => op['operation']), ['matrix_sync', 'api_request']);
      expect(retry.first.containsKey('timeline_event_count'), isFalse);
      expect(
          retry.last['operation_id'], '00000000-0000-4000-8000-000000000003');
      expect(retry.last.containsKey('started_at_utc'), isFalse);
      diagnostics.stopSession();
    });
  });

  test('oversized durable spool reports omitted operations after restart', () {
    fakeAsync((time) {
      final store = DelayedStore();
      DateTime now() => DateTime.utc(2026).add(time.elapsed);
      final original = ChatDiagnostics(now: now);
      original.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (_, __) async => 401,
          store: store,
          spoolScope: () async => scopeA);
      time.flushMicrotasks();
      for (var i = 0; i < 100; i++) {
        original.recordPerformance(PerformanceRecord(
          operationId: '00000000-0000-4000-8000-000000000001',
          operation: PerformanceOperationType.apiRequest,
          totalUs: 8000000,
          stagesUs: {
            for (var j = 0; j < 50; j++) PerformanceStage.values[j]: j * 1000,
          },
          result: PerformanceResult.failed,
          lifecycle: PerformanceLifecycle.foreground,
          frames: const PerformanceFrameCounts(),
          frameAttributionComplete: false,
        ));
      }
      time.elapse(const Duration(seconds: 2));
      time.flushMicrotasks();
      original.stopSession();
      time.flushMicrotasks();
      expect(utf8.encode(store.payload!).length,
          lessThanOrEqualTo(ChatDiagnostics.maxSpoolBytes));
      final persisted = jsonDecode(store.payload!) as Map;
      final omitted = persisted['spool_diagnostic_loss'] as Map;
      expect(omitted['dropped_operations'], greaterThan(0));
      final lossId = omitted['sample_id'];

      final batches = <ChatDiagnosticBatch>[];
      final restored = ChatDiagnostics(now: now);
      restored.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) async {
            batches.add(batch);
            return 202;
          },
          store: store,
          spoolScope: () async => scopeA);
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      expect(batches, isNotEmpty);
      expect((batches.first.toJson()['diagnostic_loss'] as Map)['sample_id'],
          lossId);
      restored.stopSession();
      time.flushMicrotasks();
    });
  });

  test('current 422 removes only watchdog stage and counts suppressed events',
      () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      final d =
          ChatDiagnostics(now: () => DateTime.utc(2026).add(time.elapsed));
      d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) async {
            batches.add(batch);
            final events = batch.toJson()['events'] as List;
            return events
                    .any((event) => event['stage'] == 'matrix_sync_soft_kick')
                ? 422
                : 202;
          });
      d.record(
          stage: ChatDiagnosticStage.matrixSend,
          error: ChatDiagnosticError.network);
      d.record(
          stage: ChatDiagnosticStage.matrixSyncSoftKick,
          error: ChatDiagnosticError.slow,
          elapsed: const Duration(seconds: 30));
      d.recordPerformance(sameRootRecord(8000));
      time.elapse(const Duration(minutes: 1));
      d.record(
          stage: ChatDiagnosticStage.matrixSyncSoftKick,
          error: ChatDiagnosticError.timeout);
      time.elapse(const Duration(minutes: 1));
      expect(batches, hasLength(2));
      final retry = batches.last.toJson();
      expect((retry['events'] as List).map((event) => event['stage']),
          ['matrixSend']);
      expect(retry['operations'], hasLength(1));
      expect((retry['diagnostic_loss'] as Map)['dropped_events'], 2);
      d.stopSession();
    });
  });

  test('regional 422 strips watchdog but preserves old event and operation',
      () {
    fakeAsync((time) {
      final store = DelayedStore();
      DateTime now() => DateTime.utc(2026).add(time.elapsed);
      final old = ChatDiagnostics(now: now);
      old.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.ios,
          upload: (_, __) async => 401,
          store: store,
          spoolScope: () async => scopeA);
      time.flushMicrotasks();
      old.record(
          stage: ChatDiagnosticStage.matrixSend,
          error: ChatDiagnosticError.network);
      old.record(
          stage: ChatDiagnosticStage.matrixSyncHardRestart,
          error: ChatDiagnosticError.timeout);
      old.recordPerformance(sameRootRecord(8000));
      time.elapse(const Duration(seconds: 2));
      time.flushMicrotasks();
      old.stopSession();
      time.flushMicrotasks();

      final batches = <ChatDiagnosticBatch>[];
      final upgraded = ChatDiagnostics(now: now);
      upgraded.startSession(
          version: '1.2.4',
          platform: ChatDiagnosticPlatform.ios,
          upload: (batch, _) async {
            batches.add(batch);
            final events = batch.toJson()['events'] as List;
            return events.any(
                    (event) => event['stage'] == 'matrix_sync_hard_restart')
                ? 422
                : 202;
          },
          store: store,
          spoolScope: () async => scopeA);
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 2));
      time.flushMicrotasks();
      expect(batches, hasLength(2));
      expect(batches.every((batch) => batch.version == '1.2.3'), isTrue);
      final retry = batches[1].toJson();
      expect((retry['events'] as List).map((event) => event['stage']),
          ['matrixSend']);
      expect(retry['operations'], hasLength(1));
      expect((retry['diagnostic_loss'] as Map)['dropped_events'], 1);
      upgraded.stopSession();
      time.flushMicrotasks();
    });
  });

  test('unsupported watchdog and loss do not delay later diagnostics', () {
    fakeAsync((time) {
      final store = DelayedStore();
      DateTime now() => DateTime.utc(2026).add(time.elapsed);
      final old = ChatDiagnostics(now: now);
      old.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.ios,
          upload: (_, __) async => 401,
          store: store,
          spoolScope: () async => scopeA);
      time.flushMicrotasks();
      old.record(
          stage: ChatDiagnosticStage.matrixSyncSoftKick,
          error: ChatDiagnosticError.timeout);
      time.elapse(const Duration(seconds: 2));
      time.flushMicrotasks();
      old.stopSession();
      time.flushMicrotasks();

      final batches = <ChatDiagnosticBatch>[];
      final upgraded = ChatDiagnostics(now: now);
      upgraded.startSession(
          version: '1.2.4',
          platform: ChatDiagnosticPlatform.ios,
          upload: (batch, _) async {
            batches.add(batch);
            final body = batch.toJson();
            final events = body['events'] as List;
            if (events.any(
                    (event) => event['stage'] == 'matrix_sync_soft_kick') ||
                body.containsKey('diagnostic_loss')) {
              return 422;
            }
            return 202;
          },
          store: store,
          spoolScope: () async => scopeA);
      time.flushMicrotasks();
      upgraded.record(
          stage: ChatDiagnosticStage.matrixSend,
          error: ChatDiagnosticError.network);
      time.elapse(const Duration(minutes: 3));
      time.flushMicrotasks();
      expect(batches, hasLength(3));
      expect(
          batches.map((batch) => batch.version), ['1.2.3', '1.2.3', '1.2.4']);
      expect((batches.last.toJson()['events'] as List).single['stage'],
          'matrixSend');
      upgraded.stopSession();
      time.flushMicrotasks();
    });
  });

  test('regional 422 strips optional observation but keeps old final', () {
    fakeAsync((time) {
      final store = DelayedStore();
      DateTime now() => DateTime.utc(2026).add(time.elapsed);
      final old = ChatDiagnostics(now: now);
      old.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (_, __) async => 401,
          store: store,
          spoolScope: () async => scopeA);
      time.flushMicrotasks();
      old.recordObservation(PerformanceTraceObservation(
          operationId: '00000000-0000-4000-8000-000000000001',
          operation: PerformanceOperationType.apiRequest,
          kind: PerformanceObservationKind.checkpoint,
          observedUs: 1000000,
          idleUs: 1000000,
          lifecycle: PerformanceLifecycle.foreground,
          stagesUs: const {}));
      old.recordPerformance(sameRootRecord(8000));
      time.elapse(const Duration(seconds: 2));
      time.flushMicrotasks();
      old.stopSession();
      time.flushMicrotasks();
      expect((jsonDecode(store.payload!) as Map)['operations'], hasLength(2));

      final batches = <ChatDiagnosticBatch>[];
      final upgraded = ChatDiagnostics(now: now);
      upgraded.startSession(
          version: '1.2.4',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) async {
            batches.add(batch);
            final ops = batch.toJson()['operations'] as List? ?? [];
            return ops.any((op) => op.containsKey('observation_kind'))
                ? 422
                : 202;
          },
          store: store,
          spoolScope: () async => scopeA);
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 2));
      time.flushMicrotasks();
      expect(batches.first.toJson()['operations'], hasLength(2));
      expect(batches, hasLength(2));
      expect(batches.every((batch) => batch.version == '1.2.3'), isTrue);
      final secondOps = batches.last.toJson()['operations'] as List;
      expect(secondOps, hasLength(1));
      expect(secondOps.single.containsKey('observation_kind'), isFalse);
      expect(secondOps.single['result'], 'failed');
      upgraded.stopSession();
      time.flushMicrotasks();
    });
  });

  test('evicted failed operation reports stable bounded loss on retry', () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      final d =
          ChatDiagnostics(now: () => DateTime.utc(2026).add(time.elapsed));
      d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) async {
            batches.add(batch);
            return batches.length == 1 ? 503 : 202;
          });
      for (var i = 0; i < 101; i++) {
        d.recordPerformance(sameRootRecord(8000));
      }
      time.elapse(const Duration(minutes: 2));
      expect(batches, hasLength(2));
      final first = batches.first.toJson()['diagnostic_loss'] as Map;
      final second = batches.last.toJson()['diagnostic_loss'] as Map;
      expect(first['dropped_operations'], 1);
      expect(first['dropped_events'], 0);
      expect(first['dropped_frames'], 0);
      expect(second, first);
      d.stopSession();
    });
  });

  test('upgraded spool retains frame tab window and loss source identity', () {
    fakeAsync((time) {
      final store = DelayedStore();
      DateTime now() => DateTime.utc(2026).add(time.elapsed);
      final original = ChatDiagnostics(now: now);
      original.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.ios,
          upload: (_, __) async => 401,
          store: store,
          spoolScope: () async => scopeA);
      time.flushMicrotasks();
      original.setFrameTab(ChatDiagnosticTab.messages);
      original.recordFrame(buildUs: 20000, rasterUs: 1000, budgetUs: 16667);
      for (var i = 0; i < 101; i++) {
        original.record(
            stage: ChatDiagnosticStage.matrixSend,
            error: ChatDiagnosticError.network,
            status: 100 + i);
      }
      time.elapse(const Duration(seconds: 2));
      time.flushMicrotasks();
      final local = jsonDecode(store.payload!) as Map;
      final localWindow = (local['frame_windows'] as List).single;
      final localLoss = (local['diagnostic_losses'] as List).single;
      expect(localWindow['active_tab'], 'messages');
      expect(localLoss['dropped_events'], 1);
      original.stopSession();
      time.flushMicrotasks();

      final batches = <ChatDiagnosticBatch>[];
      final upgraded = ChatDiagnostics(now: now);
      upgraded.startSession(
          version: '1.2.4',
          platform: ChatDiagnosticPlatform.ios,
          upload: (batch, _) async {
            batches.add(batch);
            return 503;
          },
          store: store,
          spoolScope: () async => scopeA);
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      expect(batches, isNotEmpty);
      expect(batches.first.version, '1.2.3');
      expect(batches.first.platform, ChatDiagnosticPlatform.ios);
      final first = batches.first.toJson();
      expect((first['frame_windows'] as List).single['window_id'],
          localWindow['window_id']);
      expect((first['diagnostic_loss'] as Map)['sample_id'],
          localLoss['sample_id']);
      upgraded.stopSession();
      time.flushMicrotasks();
    });
  });

  test('upgraded spool keeps operation under its source version after retry',
      () {
    fakeAsync((time) {
      final store = DelayedStore();
      DateTime now() => DateTime(2026).add(time.elapsed);
      final previous = ChatDiagnostics(now: now);
      previous.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (_, __) async => 401,
          store: store,
          spoolScope: () async => scopeA);
      time.flushMicrotasks();
      previous.recordPerformance(
          sameRootRecord(8000, operation: PerformanceOperationType.matrixSync));
      time.elapse(const Duration(seconds: 2));
      time.flushMicrotasks();
      previous.stopSession();
      time.flushMicrotasks();

      final attempts = <ChatDiagnosticBatch>[];
      final upgraded = ChatDiagnostics(now: now);
      upgraded.startSession(
          version: '1.2.4',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) async {
            attempts.add(batch);
            return 503;
          },
          store: store,
          spoolScope: () async => scopeA);
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      expect(attempts, hasLength(1));
      expect(attempts.single.version, '1.2.3');
      final first = attempts.single.toJson()['operations'] as List;
      expect(first, hasLength(1));
      expect(first.single['operation'], 'matrix_sync');
      expect(first.single['total_ms'], 8000);
      upgraded.stopSession();
      time.flushMicrotasks();

      final delivered = <ChatDiagnosticBatch>[];
      final restored = ChatDiagnostics(now: now);
      restored.startSession(
          version: '1.2.4',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) async {
            delivered.add(batch);
            return 202;
          },
          store: store,
          spoolScope: () async => scopeA);
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      expect(delivered, hasLength(1));
      expect(delivered.single.version, '1.2.3');
      expect(delivered.single.toJson()['operations'], first);
      restored.stopSession();
      time.flushMicrotasks();
    });
  });

  test('detailed failure admission triggers one-second durable spool', () {
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
      final attempt = d.networks.begin(
          method: 'GET',
          uri: Uri.parse('https://api.example.test/api/v1/profile'))!;
      attempt.error(TimeoutException('diagnostic test'));
      time.elapse(const Duration(seconds: 2));
      time.flushMicrotasks();
      expect(store.payload, contains('network_requests'));
      expect((jsonDecode(store.payload!) as Map)['network_requests'],
          hasLength(1));
      d.stopSession();
      time.flushMicrotasks();
    });
  });

  test('same-root wallet and two API records survive durable restore', () {
    fakeAsync((time) {
      final store = DelayedStore();
      final original =
          ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      void start(ChatDiagnostics diagnostics) => diagnostics.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (_, __) async => 401,
          store: store,
          spoolScope: () async => scopeA);
      start(original);
      time.flushMicrotasks();
      original.recordPerformance(
          sameRootRecord(100, operation: PerformanceOperationType.walletLoad));
      original.recordPerformance(sameRootRecord(200));
      original.recordPerformance(sameRootRecord(300));
      time.elapse(const Duration(seconds: 2));
      time.flushMicrotasks();
      original.stopSession();
      time.flushMicrotasks();
      final restored =
          ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      start(restored);
      time.flushMicrotasks();
      expect(restored.pendingCount, 3);
      final saved = jsonDecode(store.payload!) as Map;
      expect(saved['schema'], 3);
      final entries = saved['operations'] as List;
      expect(entries.map((entry) => entry['queue_entry_id']).toSet(),
          hasLength(3));
      expect(
          entries.map((entry) => entry['operation_id']).toSet(), hasLength(1));
      restored.stopSession();
      time.flushMicrotasks();
    });
  });

  test('same-root v2 migration preserves each record and adds local identity',
      () {
    fakeAsync((time) {
      final store = DelayedStore()
        ..payload = jsonEncode({
          'schema': 2,
          'scope': scopeA,
          'created_ms': DateTime(2026).millisecondsSinceEpoch,
          'events': [],
          'operations': [
            for (final record in [
              sameRootRecord(100,
                  operation: PerformanceOperationType.walletLoad),
              sameRootRecord(200),
              sameRootRecord(300)
            ])
              {...record.toJson(), 'frames_total': 0}
          ]
        });
      final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (_, __) async => 401,
          store: store,
          spoolScope: () async => scopeA);
      time.flushMicrotasks();
      expect(d.pendingCount, 3);
      expect((jsonDecode(store.payload!) as Map)['schema'], 3);
      d.stopSession();
      time.flushMicrotasks();
    });
  });

  for (final replaceAfterExpiry in [false, true]) {
    test('same-root held ACK preserves new record expiry=$replaceAfterExpiry',
        () {
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
        d.recordPerformance(sameRootRecord(100,
            operation: PerformanceOperationType.walletLoad));
        d.recordPerformance(sameRootRecord(200));
        d.recordPerformance(sameRootRecord(300));
        time.elapse(const Duration(minutes: 1));
        time.flushMicrotasks();
        expect(batches.single.toJson()['operations'], hasLength(3));
        if (replaceAfterExpiry) time.elapse(const Duration(hours: 25));
        d.recordPerformance(sameRootRecord(400));
        held.complete(202);
        time.flushMicrotasks();
        expect(d.pendingCount, 1);
        time.elapse(const Duration(minutes: 1));
        time.flushMicrotasks();
        final operation =
            (batches.last.toJson()['operations'] as List).single as Map;
        expect(operation['total_ms'], 400);
        expect(operation.containsKey('queue_entry_id'), isFalse);
        expect(d.pendingCount, 0);
        d.stopSession();
        time.flushMicrotasks();
      });
    });
  }

  for (final oldStatus in [202, 401]) {
    test('same-root late $oldStatus cannot ACK or back off a new account', () {
      fakeAsync((time) {
        final heldUpload = Completer<int>();
        final oldBatches = <ChatDiagnosticBatch>[];
        final newBatches = <ChatDiagnosticBatch>[];
        final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
        d.startSession(
            version: '1.2.3',
            platform: ChatDiagnosticPlatform.android,
            upload: (batch, _) {
              oldBatches.add(batch);
              return heldUpload.future;
            });
        d.recordPerformance(sameRootRecord(100));
        time.elapse(const Duration(minutes: 1));
        time.flushMicrotasks();
        expect(oldBatches, hasLength(1));

        d.startSession(
            version: '1.2.3',
            platform: ChatDiagnosticPlatform.android,
            upload: (batch, _) async {
              newBatches.add(batch);
              return 202;
            });
        d.recordPerformance(sameRootRecord(400));
        heldUpload.complete(oldStatus);
        time.flushMicrotasks();
        expect(d.pendingCount, 1);
        time.elapse(const Duration(minutes: 1));
        time.flushMicrotasks();
        expect(newBatches, hasLength(1));
        final fresh =
            (newBatches.single.toJson()['operations'] as List).single as Map;
        expect(fresh['total_ms'], 400);
        expect(fresh, isNot(contains('queue_entry_id')));
        expect(d.pendingCount, 0);
        d.stopSession();
      });
    });
  }
  test('queue identity v3 validates UUID and deduplicates only the same entry',
      () {
    fakeAsync((time) {
      final valid = {
        ...sameRootRecord(100).toJson(),
        'frames_total': 0,
        'queue_entry_id': '00000000-0000-4000-8000-000000000011'
      };
      final store = DelayedStore()
        ..payload = jsonEncode({
          'schema': 3,
          'scope': scopeA,
          'created_ms': DateTime(2026).millisecondsSinceEpoch,
          'events': [],
          'operations': [
            valid,
            valid,
            {
              ...sameRootRecord(200).toJson(),
              'frames_total': 0,
              'queue_entry_id': '00000000-0000-4000-8000-000000000012'
            },
            {...valid, 'queue_entry_id': 'PRIVATE'},
            {
              ...valid,
              'queue_entry_id': '00000000-0000-4000-8000-000000000013',
              'message': 'PRIVATE'
            }
          ]
        });
      final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (_, __) async => 401,
          store: store,
          spoolScope: () async => scopeA);
      time.flushMicrotasks();
      expect(d.pendingCount, 2);
      expect(store.payload, isNot(contains('PRIVATE')));
      d.stopSession();
      time.flushMicrotasks();
    });
  });

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
