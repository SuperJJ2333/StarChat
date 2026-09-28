import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/chat_diagnostics.dart';
import 'package:liuhetong_mobile/core/performance_trace_model.dart';

String operationId(int n) =>
    '00000000-0000-4000-8000-${n.toRadixString(16).padLeft(12, '0')}';

PerformanceRecord record(int n,
        {PerformanceOperationType operation =
            PerformanceOperationType.apiRequest,
        PerformanceResult result = PerformanceResult.success,
        int millis = 100}) =>
    PerformanceRecord(
        operationId: operationId(n),
        operation: operation,
        totalUs: millis * 1000,
        stagesUs: const {},
        result: result,
        lifecycle: PerformanceLifecycle.foreground,
        frames: const PerformanceFrameCounts(),
        frameAttributionComplete: false);

PerformanceTraceObservation observation(int n,
        {PerformanceObservationKind kind =
            PerformanceObservationKind.checkpoint}) =>
    PerformanceTraceObservation(
        operationId: operationId(n),
        operation: PerformanceOperationType.apiRequest,
        kind: kind,
        observedUs: 2000000,
        idleUs: 2000000,
        stagesUs: const {},
        lifecycle: PerformanceLifecycle.foreground);

List<String> uploadedIds(List<ChatDiagnosticBatch> batches) => [
      for (final batch in batches)
        for (final operation
            in batch.toJson()['operations'] as List? ?? const [])
          operation['operation_id'] as String
    ];

void main() {
  test(
      'full queue retains new video failure through routine and slow API churn',
      () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      final d = ChatDiagnostics(
          now: () => DateTime(2026).add(time.elapsed),
          normalSamplePercent: 100);
      d.startSession(
          version: '0.4.13+2180',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) async {
            batches.add(batch);
            return 202;
          });
      for (var n = 1; n <= 100; n++) {
        d.recordPerformance(record(n));
      }
      d.recordPerformance(record(101,
          operation: PerformanceOperationType.videoPrepare,
          result: PerformanceResult.failed));
      for (var n = 102; n <= 141; n++) {
        d.recordPerformance(record(n, millis: 2000));
        d.recordObservation(observation(n + 1000));
        expect(d.pendingCount, 100);
      }
      for (var minute = 0; minute < 6; minute++) {
        time.elapse(const Duration(minutes: 1));
        time.flushMicrotasks();
      }
      expect(uploadedIds(batches), contains(operationId(101)));
      expect(d.pendingCount, 0);
      d.stopSession();
    });
  });

  test('overflow evicts oldest eligible records and keeps expired evidence',
      () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      final d = ChatDiagnostics(
          now: () => DateTime(2026).add(time.elapsed),
          normalSamplePercent: 100);
      d.startSession(
          version: '0.4.13+2180',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) async {
            batches.add(batch);
            return 202;
          });
      for (var n = 1; n <= 100; n++) {
        d.recordPerformance(record(n));
      }
      d.recordObservation(
          observation(101, kind: PerformanceObservationKind.expired));
      d.recordPerformance(record(102, millis: 2000));
      for (var minute = 0; minute < 6; minute++) {
        time.elapse(const Duration(minutes: 1));
        time.flushMicrotasks();
      }
      final ids = uploadedIds(batches);
      expect(ids, contains(operationId(101)));
      expect(ids, contains(operationId(102)));
      expect(ids, isNot(contains(operationId(1))));
      expect(ids, isNot(contains(operationId(2))));
      expect(ids.toSet(), hasLength(100));
      d.stopSession();
    });
  });

  test(
      'overflow protects only actual frozen batch and ACK cannot erase new error',
      () {
    fakeAsync((time) {
      final held = Completer<int>();
      final batches = <ChatDiagnosticBatch>[];
      final d = ChatDiagnostics(
          now: () => DateTime(2026).add(time.elapsed),
          normalSamplePercent: 100);
      d.startSession(
          version: '0.4.13+2180',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) {
            batches.add(batch);
            return batches.length == 1 ? held.future : Future.value(202);
          });
      for (var n = 1; n <= 100; n++) {
        d.recordPerformance(record(n));
      }
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      final frozen = uploadedIds(batches).toSet();
      expect(frozen, hasLength(20));
      d.recordPerformance(record(101,
          operation: PerformanceOperationType.videoPrepare,
          result: PerformanceResult.failed));
      for (var n = 102; n <= 131; n++) {
        d.recordPerformance(record(n, millis: 2000));
      }
      held.complete(202);
      time.flushMicrotasks();
      expect(d.pendingCount, 80);
      for (var minute = 0; minute < 5; minute++) {
        time.elapse(const Duration(minutes: 1));
        time.flushMicrotasks();
      }
      final ids = uploadedIds(batches);
      expect(ids, contains(operationId(101)));
      expect(ids, isNot(contains(operationId(21))));
      for (final id in frozen) {
        expect(ids.where((value) => value == id), hasLength(1));
      }
      expect(ids.toSet(), hasLength(ids.length));
      expect(d.pendingCount, 0);
      d.stopSession();
    });
  });

  test('normal churn cannot replace a queue containing only errors', () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      final d = ChatDiagnostics(
          now: () => DateTime(2026).add(time.elapsed),
          normalSamplePercent: 100);
      d.startSession(
          version: '0.4.13+2180',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) async {
            batches.add(batch);
            return 202;
          });
      for (var n = 1; n <= 100; n++) {
        d.recordPerformance(record(n, result: PerformanceResult.failed));
      }
      d.recordPerformance(record(101, millis: 2000));
      d.recordObservation(observation(102));
      for (var minute = 0; minute < 6; minute++) {
        time.elapse(const Duration(minutes: 1));
        time.flushMicrotasks();
      }
      expect(uploadedIds(batches).toSet(),
          {for (var n = 1; n <= 100; n++) operationId(n)});
      d.stopSession();
    });
  });

  test('small upload freezes actual body-sized batch rather than first 20', () {
    fakeAsync((time) {
      final held = Completer<int>();
      final batches = <ChatDiagnosticBatch>[];
      final d = ChatDiagnostics(
          now: () => DateTime(2026).add(time.elapsed),
          normalSamplePercent: 100,
          maxUploadBytes: 600);
      d.startSession(
          version: '0.4.13+2180',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) {
            batches.add(batch);
            return batches.length == 1 ? held.future : Future.value(202);
          });
      for (var n = 1; n <= 100; n++) {
        d.recordPerformance(record(n));
      }
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      final frozen = uploadedIds(batches);
      expect(frozen.length, inInclusiveRange(1, 19));
      d.recordPerformance(record(101, result: PerformanceResult.failed));
      held.complete(202);
      time.flushMicrotasks();
      for (var minute = 0; minute < 100; minute++) {
        time.elapse(const Duration(minutes: 1));
        time.flushMicrotasks();
      }
      final ids = uploadedIds(batches);
      expect(ids, contains(operationId(101)));
      expect(ids, isNot(contains(operationId(frozen.length + 1))));
      expect(ids.toSet(), hasLength(100));
      expect(d.pendingCount, 0);
      d.stopSession();
    });
  });

  test('failed upload releases its oldest eligible entries for later overflow',
      () {
    fakeAsync((time) {
      final held = Completer<int>();
      final batches = <ChatDiagnosticBatch>[];
      final d = ChatDiagnostics(
          now: () => DateTime(2026).add(time.elapsed),
          normalSamplePercent: 100);
      d.startSession(
          version: '0.4.13+2180',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) {
            batches.add(batch);
            return batches.length == 1 ? held.future : Future.value(202);
          });
      for (var n = 1; n <= 100; n++) {
        d.recordPerformance(record(n));
      }
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      d.recordPerformance(record(101, result: PerformanceResult.failed));
      held.complete(401);
      time.flushMicrotasks();
      d.recordPerformance(record(102, result: PerformanceResult.failed));
      expect(d.pendingCount, 100);
      for (var minute = 0; minute < 6; minute++) {
        time.elapse(const Duration(minutes: 1));
        time.flushMicrotasks();
      }
      final successfulIds = uploadedIds(batches.skip(1).toList());
      expect(successfulIds, isNot(contains(operationId(1))));
      expect(successfulIds, contains(operationId(2)));
      expect(successfulIds, containsAll([operationId(101), operationId(102)]));
      expect(successfulIds.toSet(), hasLength(100));
      d.stopSession();
    });
  });

  test('performance failure cannot evict a legacy event in held upload', () {
    fakeAsync((time) {
      final held = Completer<int>();
      final batches = <ChatDiagnosticBatch>[];
      final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      d.startSession(
          version: '0.4.13+2180',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) {
            batches.add(batch);
            return batches.length == 1 ? held.future : Future.value(202);
          });
      for (var n = 100; n < 200; n++) {
        d.record(
            stage: ChatDiagnosticStage.networkRequest,
            error: ChatDiagnosticError.network,
            status: n);
      }
      time.elapse(const Duration(minutes: 1));
      time.flushMicrotasks();
      d.recordPerformance(record(101, result: PerformanceResult.failed));
      // Same legacy aggregate changed during upload must survive the old ACK.
      d.record(
          stage: ChatDiagnosticStage.networkRequest,
          error: ChatDiagnosticError.network,
          status: 100);
      held.complete(202);
      time.flushMicrotasks();
      expect(d.pendingCount, 81);
      for (var minute = 0; minute < 6; minute++) {
        time.elapse(const Duration(minutes: 1));
        time.flushMicrotasks();
      }
      final events = [
        for (final batch in batches)
          for (final event in batch.toJson()['events'] as List) event
      ];
      expect(events.where((event) => event['status'] == 100), hasLength(2));
      expect(events.where((event) => event['status'] == 120), isEmpty);
      expect(uploadedIds(batches), [operationId(101)]);
      expect(d.pendingCount, 0);
      d.stopSession();
    });
  });

  test(
      'new legacy network error replaces routine API evidence at full capacity',
      () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      final d = ChatDiagnostics(
          now: () => DateTime(2026).add(time.elapsed),
          normalSamplePercent: 100);
      d.startSession(
          version: '0.4.13+2180',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) async {
            batches.add(batch);
            return 202;
          });
      for (var n = 1; n <= 100; n++) {
        d.recordPerformance(record(n));
      }
      d.record(
          stage: ChatDiagnosticStage.networkRequest,
          error: ChatDiagnosticError.network,
          elapsed: const Duration(seconds: 2));
      expect(d.pendingCount, 100);
      for (var minute = 0; minute < 6; minute++) {
        time.elapse(const Duration(minutes: 1));
        time.flushMicrotasks();
      }
      final events = [
        for (final batch in batches)
          for (final event in batch.toJson()['events'] as List) event
      ];
      expect(events, hasLength(1));
      expect(events.single['stage'], 'network_request');
      expect(events.single['error'], 'network');
      expect(events.single['elapsed_ms'], 2000);
      expect(uploadedIds(batches), isNot(contains(operationId(1))));
      expect(uploadedIds(batches), hasLength(99));
      expect(d.pendingCount, 0);
      d.stopSession();
    });
  });

  test('mixed queue evicts a legacy slow event before a performance failure',
      () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      final d = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      d.startSession(
          version: '0.4.13+2180',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) async {
            batches.add(batch);
            return 202;
          });
      for (var n = 1; n <= 99; n++) {
        d.recordPerformance(record(n, result: PerformanceResult.failed));
      }
      d.record(
          stage: ChatDiagnosticStage.historyLoad,
          error: ChatDiagnosticError.slow,
          elapsed: const Duration(seconds: 1));
      d.recordPerformance(record(100, result: PerformanceResult.failed));
      for (var minute = 0; minute < 6; minute++) {
        time.elapse(const Duration(minutes: 1));
        time.flushMicrotasks();
      }
      expect(uploadedIds(batches).toSet(),
          {for (var n = 1; n <= 100; n++) operationId(n)});
      expect(
          batches.every((batch) => (batch.toJson()['events'] as List).isEmpty),
          isTrue);
      d.stopSession();
    });
  });
}
