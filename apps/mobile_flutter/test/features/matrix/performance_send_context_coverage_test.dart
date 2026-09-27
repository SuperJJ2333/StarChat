import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_room_timeline_adapter.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_outgoing_work_coordinator.dart';
import 'package:liuhetong_mobile/features/matrix/logical_conversation_timeline.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'room_timeline_controller_test.dart' show FakeTimelineAdapter;
import 'video_forward_backend_test.dart'
    show ForwardClient, ForwardRoom, ForwardPaths, forwardOwner;
import 'matrix_room_timeline_adapter_test.dart'
    show RetryRoom, RetryTimeline, RetryEvent, OutgoingRetryClient;

final class RetryFailureAdapter extends FakeTimelineAdapter
    implements RoomRetryDiagnostics {
  Object? failure;
  void Function()? onRetry;
  Completer<void>? heldRetry;
  bool noop = false;
  @override
  Future<void> retry(String transactionId) async {
    retryCalls++;
    onRetry?.call();
    await heldRetry?.future;
    if (failure case final Object error) throw error;
  }

  @override
  Future<void> retryWithDiagnostics(
      String transactionId, PerformanceTrace Function() startSdkAttempt) async {
    if (noop) return;
    final trace = startSdkAttempt();
    trace.mark(PerformanceStage.matrixSendStart);
    try {
      await retry(transactionId);
      trace.mark(PerformanceStage.ack);
    } finally {
      trace.mark(PerformanceStage.matrixSendFinish);
    }
  }
}

final class RetryMediaRoom extends ForwardRoom {
  RetryMediaRoom({required super.id, required super.client});
  void Function()? onSend;
  @override
  Future<String?> sendFileEvent(MatrixFile file,
      {String? txid,
      Event? inReplyTo,
      String? editEventId,
      int? shrinkImageMaxDimension,
      MatrixImageFile? thumbnail,
      Map<String, dynamic>? extraContent,
      String? threadRootEventId,
      String? threadLastEventId}) async {
    onSend?.call();
    if (failuresBeforeSend-- > 0) throw TimeoutException('private');
    return r'$fixture';
  }

  @override
  Future<String?> sendEvent(Map<String, dynamic> content,
      {String type = EventTypes.Message,
      String? txid,
      Event? inReplyTo,
      String? editEventId,
      String? threadRootEventId,
      String? threadLastEventId}) async {
    onSend?.call();
    return r'$fixture';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  for (final fail in [false, true]) {
    test(
        'SDK-only retry emits actual ${fail ? 'failure' : 'success'} without local echo',
        () async {
      var now = 0;
      final records = <PerformanceRecord>[];
      final recorder = PerformanceTraceRecorder(
          enabled: () => true, clockUs: () => now, onRecord: records.add);
      final adapter = RetryFailureAdapter()
        ..failure = fail ? TimeoutException('private payload') : null
        ..onRetry = () => now = 17000;
      final controller =
          RoomTimelineController(adapter, performanceRecorder: recorder);
      if (fail) {
        await expectLater(controller.retry('private-transaction'),
            throwsA(isA<TimeoutException>()));
      } else {
        await controller.retry('private-transaction');
      }
      expect(adapter.retryCalls, 1);
      expect(records, hasLength(1));
      final record = records.single;
      expect(record.operation, PerformanceOperationType.messageSend);
      expect(record.result,
          fail ? PerformanceResult.failed : PerformanceResult.success);
      expect(
          record.betweenMs(PerformanceStage.matrixSendStart,
              PerformanceStage.matrixSendFinish),
          17);
      expect(record.stagesUs.containsKey(PerformanceStage.composerSubmit),
          isFalse);
      expect(
          record.stagesUs.containsKey(PerformanceStage.outboxPersist), isFalse);
      expect(record.networkError,
          fail ? PerformanceNetworkError.requestTimeout : null);
      expect(recorder.activeCount, 0);
      expect(jsonEncode(record.toJson()), isNot(contains('private')));
      controller.dispose();
      recorder.clear();
    });
  }
  for (final prepared in [false, true]) {
    test(
        '${prepared ? 'prepared media' : 'forward'} job supplies one anonymous context to all targets',
        () async {
      final client = ForwardClient();
      final a = ForwardRoom(id: '!private-a:test', client: client);
      final b = ForwardRoom(id: '!private-b:test', client: client);
      client.destinations.addAll({a.id: a, b.id: b});
      final owner = forwardOwner(client);
      owner.authorizeRoomSend = (_, __, ___) async => false;
      final job = prepared
          ? await owner.enqueuePreparedMedia(
              jobId: 'private-media',
              media: MatrixOutgoingPreparedMedia(
                  id: 'private-source',
                  bytes: [1, 2],
                  mimeType: 'video/mp4',
                  filename: 'private.mp4',
                  body: 'private-body'),
              targetRoomIds: [a.id, b.id])
          : (await owner.enqueueForward(batchId: 'private-forward', messages: [
              MatrixOutgoingForwardText(
                  id: 'private-source', body: 'private-body')
            ], targetRoomIds: [
              a.id,
              b.id
            ]))
              .single;
      await owner.outgoingWork.drain();
      final context = job.items.first.performanceContext;
      expect(context, isNotNull);
      expect(job.items.last.performanceContext, same(context));
      expect(context!.operationId, isNot(contains('private')));
      for (final item in job.items) {
        owner.outgoingWork.cancelItem(job.id, item.id);
      }
      await owner.outgoingWork.drain();
      expect(context.isCurrent, isFalse);
    });
  }
  test('successive SDK retries share a bounded account-scoped job identity',
      () async {
    var generation = 1;
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
        enabled: () => true,
        sessionGeneration: () => generation,
        onRecord: records.add);
    final adapter = RetryFailureAdapter()
      ..failure = TimeoutException('private');
    final controller =
        RoomTimelineController(adapter, performanceRecorder: recorder);
    await expectLater(
        controller.retry('private-tx'), throwsA(isA<TimeoutException>()));
    await expectLater(
        controller.retry('private-tx'), throwsA(isA<TimeoutException>()));
    expect(records, hasLength(2));
    expect(records[1].operationId, records[0].operationId);
    expect(records[1].retryCount, greaterThan(records[0].retryCount));
    expect(recorder.activeCount, 0);
    generation++;
    adapter.failure = null;
    await controller.retry('private-tx');
    expect(records, hasLength(3));
    expect(records.last.operationId, isNot(records.first.operationId));
    controller.dispose();
    recorder.clear();
  });

  test(
      'video selected at capacity later measures preparation and retry with same root',
      () async {
    var now = 0;
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true),
        activeCapacity: 1,
        clockUs: () => now,
        onRecord: records.add);
    final busy = recorder.start(PerformanceOperationType.apiRequest);
    final root = recorder.start(PerformanceOperationType.videoPrepare);
    root.mark(PerformanceStage.videoSelected);
    expect(root.isRecording, isFalse);
    expect(recorder.activeCount, 1);
    busy.finish();
    now = 1000000;
    final client = ForwardClient();
    final target = RetryMediaRoom(id: '!private:test', client: client)
      ..failuresBeforeSend = 1;
    client.destinations[target.id] = target;
    final owner = forwardOwner(client);
    final directory = Directory(
        '../../docs/verification/artifacts/2026-09-26/network-diagnostics-remediation/send-context-cases');
    await directory.create(recursive: true);
    final fixture = await directory.createTemp('video-');
    final paths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = ForwardPaths(fixture.absolute.path);
    addTearDown(() async {
      PathProviderPlatform.instance = paths;
      expect(fixture.absolute.path.startsWith(directory.absolute.path), isTrue);
      await fixture.delete(recursive: true);
    });
    final file = await File('${fixture.path}/source.mp4').writeAsBytes([1]);
    final job = await owner.enqueueVideoFile(
        jobId: 'private-job',
        video: MatrixOutgoingVideoFile.forTesting(
            id: 'private-source',
            source: file,
            filename: 'private.mp4',
            body: 'private',
            deleteSourceWhenDone: false,
            performanceTrace: root,
            prepareMedia: (_) async {
              now += 20000;
              return MatrixOutgoingPreparedMedia(
                  id: 'prepared',
                  bytes: [1, 2],
                  mimeType: 'video/mp4',
                  filename: 'private.mp4',
                  body: 'private');
            }),
        targetRoomIds: [target.id]);
    await owner.outgoingWork.drain();
    await owner.outgoingWork.retryItem(job.id, job.items.single.id);
    await owner.outgoingWork.drain();
    final spans = records
        .where(
            (record) => record.operation != PerformanceOperationType.apiRequest)
        .toList();
    expect(spans, hasLength(3));
    expect(spans.every((record) => record.operationId == root.operationId),
        isTrue);
    expect(spans.first.operation, PerformanceOperationType.videoPrepare);
    expect(spans.first.totalMs, 20);
    expect(spans.first.stagesUs.containsKey(PerformanceStage.videoSelected),
        isFalse);
    expect(spans.last.retryCount, 1);
    expect(spans.last.result, PerformanceResult.success);
    expect(recorder.activeCount, 0);
    recorder.clear();
  });
  for (final prepared in [false, true]) {
    test(
        '${prepared ? 'prepared media' : 'forward text'} measures its actual SDK call',
        () async {
      var now = 0;
      final records = <PerformanceRecord>[];
      final recorder = PerformanceTraceRecorder(
          enabled: () => true, clockUs: () => now, onRecord: records.add);
      final client = ForwardClient();
      final room = RetryMediaRoom(id: '!private:test', client: client)
        ..onSend = () => now += 17000;
      client.destinations[room.id] = room;
      final owner = MatrixSdkE2eeClient(client,
          homeserver: Uri.parse('https://test'),
          performanceRecorder: recorder,
          readContinuityMetadata: (active) async =>
              MatrixClientContinuityMetadata(
                  isLoggedIn: true,
                  userId: active.userID,
                  deviceId: active.deviceID,
                  ed25519Fingerprint: 'fixture',
                  databaseGeneration: 'fixture'));
      final base = Directory(
          '../../docs/verification/artifacts/2026-09-26/network-diagnostics-remediation/send-context-cases');
      await base.create(recursive: true);
      final fixture = await base.createTemp('sdk-');
      final paths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = ForwardPaths(fixture.absolute.path);
      addTearDown(() async {
        PathProviderPlatform.instance = paths;
        expect(fixture.absolute.path.startsWith(base.absolute.path), isTrue);
        await fixture.delete(recursive: true);
      });
      final job = prepared
          ? await owner.enqueuePreparedMedia(
              jobId: 'private-media',
              media: MatrixOutgoingPreparedMedia(
                  id: 'private-source',
                  bytes: [1, 2],
                  mimeType: 'video/mp4',
                  filename: 'private.mp4',
                  body: 'private'),
              targetRoomIds: [room.id])
          : (await owner.enqueueForward(batchId: 'private-forward', messages: [
              MatrixOutgoingForwardText(id: 'private-source', body: 'private')
            ], targetRoomIds: [
              room.id
            ]))
              .single;
      await owner.outgoingWork.drain();
      expect(records, hasLength(1));
      final record = records.single;
      expect(
          record.operationId, job.items.single.performanceContext!.operationId);
      expect(record.result, PerformanceResult.success);
      expect(
          record.betweenMs(PerformanceStage.matrixSendStart,
              PerformanceStage.matrixSendFinish),
          17);
      expect(record.stagesUs.containsKey(PerformanceStage.composerSubmit),
          isFalse);
      expect(
          record.stagesUs.containsKey(PerformanceStage.outboxPersist), isFalse);
      expect(jsonEncode(record.toJson()), isNot(contains('private')));
      recorder.clear();
    });
  }
  test('SDK retry context expires at original five-minute deadline', () {
    fakeAsync((clock) {
      final records = <PerformanceRecord>[];
      final recorder = PerformanceTraceRecorder(
          enabled: () => true,
          clockUs: () => clock.elapsed.inMicroseconds,
          onRecord: records.add);
      final adapter = RetryFailureAdapter()
        ..failure = TimeoutException('private');
      final controller =
          RoomTimelineController(adapter, performanceRecorder: recorder);
      void retry() {
        controller.retry('private-tx').then((_) {}, onError: (Object _) {});
        clock.flushMicrotasks();
      }

      retry();
      clock.elapse(const Duration(minutes: 4));
      retry();
      expect(records[1].operationId, records[0].operationId);
      clock.elapse(const Duration(minutes: 1));
      retry();
      expect(records[2].operationId, isNot(records[0].operationId));
      expect(recorder.activeCount, 0);
      controller.dispose();
      recorder.clear();
      expect(clock.pendingTimers, isEmpty);
    });
  });
  test('SDK retry leases evict at the existing active capacity', () async {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
        enabled: () => true, activeCapacity: 1, onRecord: records.add);
    final adapter = RetryFailureAdapter()
      ..failure = TimeoutException('private');
    final controller =
        RoomTimelineController(adapter, performanceRecorder: recorder);
    for (final tx in ['private-a', 'private-b', 'private-a']) {
      await expectLater(controller.retry(tx), throwsA(isA<TimeoutException>()));
    }
    expect(records, hasLength(3));
    expect(records[2].operationId, isNot(records[0].operationId));
    expect(recorder.activeCount, 0);
    controller.dispose();
    recorder.clear();
  });
  test(
      'real adapter queued retry does not report SDK ACK before held work fails',
      () async {
    final records = <PerformanceRecord>[];
    final recorder =
        PerformanceTraceRecorder(enabled: () => true, onRecord: records.add);
    final context = recorder.createCorrelationContext();
    final client = OutgoingRetryClient();
    final room = RetryRoom(client: client);
    client.room = room;
    room.timeline = RetryTimeline();
    final owner = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://test'),
        readContinuityMetadata: (active) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: true,
                userId: active.userID,
                deviceId: active.deviceID,
                ed25519Fingerprint: 'fixture',
                databaseGeneration: 'fixture'));
    final lease = await owner.openRoomLease(room.id);
    final adapter = MatrixRoomTimelineAdapter(
        await lease.openRoomTimeline(onUpdate: () {}));
    final pending = Completer<String>();
    var calls = 0;
    await owner.outgoingWork
        .enqueue(MatrixOutgoingWorkJob(id: 'private-job', items: [
      MatrixOutgoingWorkItem(
          id: 'private-item',
          targetRoomId: room.id,
          txid: 'private-tx',
          performanceContext: context,
          send: (attempt) async {
            attempt.performanceTrace?.mark(PerformanceStage.matrixSendStart);
            try {
              if (calls++ == 0) throw TimeoutException('private');
              return await pending.future;
            } finally {
              attempt.performanceTrace?.mark(PerformanceStage.matrixSendFinish);
            }
          })
    ]));
    await owner.outgoingWork.drain();
    records.clear();
    final controller =
        RoomTimelineController(adapter, performanceRecorder: recorder);
    await controller.retry('private-tx');
    expect(records, isEmpty,
        reason: 'queued admission is not SDK completion or ACK');
    pending.completeError(TimeoutException('private'));
    await owner.outgoingWork.drain();
    expect(records, hasLength(1));
    expect(records.single.operationId, context.operationId);
    expect(records.single.result, PerformanceResult.failed);
    expect(records.single.stagesUs.containsKey(PerformanceStage.ack), isFalse);
    controller.dispose();
    await lease.cancel();
    context.close();
    recorder.clear();
  });
  test('no-op retry reports no fabricated SDK completion', () async {
    final records = <PerformanceRecord>[];
    final recorder =
        PerformanceTraceRecorder(enabled: () => true, onRecord: records.add);
    final controller = RoomTimelineController(
        RetryFailureAdapter()..noop = true,
        performanceRecorder: recorder);
    await controller.retry('private');
    expect(records, isEmpty);
    expect(recorder.activeCount, 0);
    controller.dispose();
    recorder.clear();
  });
  for (final fail in [false, true]) {
    test(
        'disposing held actual SDK retry preserves its ${fail ? 'failure' : 'success'}',
        () async {
      final records = <PerformanceRecord>[];
      final recorder =
          PerformanceTraceRecorder(enabled: () => true, onRecord: records.add);
      final held = Completer<void>();
      final adapter = RetryFailureAdapter()
        ..heldRetry = held
        ..failure = fail ? TimeoutException('private') : null;
      final controller =
          RoomTimelineController(adapter, performanceRecorder: recorder);
      final retry = controller.retry('private');
      controller.dispose();
      expect(records, isEmpty,
          reason: 'disposal cannot cancel business SDK Future');
      held.complete();
      if (fail) {
        await expectLater(retry, throwsA(isA<TimeoutException>()));
      } else {
        await retry;
      }
      expect(records, hasLength(1));
      expect(records.single.result,
          fail ? PerformanceResult.failed : PerformanceResult.success);
      expect(
          records.single.stagesUs
              .containsKey(PerformanceStage.timelinePublished),
          isFalse);
      recorder.clear();
    });
  }
  test(
      'actual SDK retry counter survives initial observation-capacity rejection',
      () async {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
        enabled: () => true, activeCapacity: 1, onRecord: records.add);
    final busy = recorder.start(PerformanceOperationType.apiRequest);
    final controller = RoomTimelineController(
        RetryFailureAdapter()..failure = TimeoutException('private'),
        performanceRecorder: recorder);
    await expectLater(
        controller.retry('private'), throwsA(isA<TimeoutException>()));
    expect(records, isEmpty);
    busy.finish();
    records.clear();
    await expectLater(
        controller.retry('private'), throwsA(isA<TimeoutException>()));
    expect(records, hasLength(1));
    expect(records.single.retryCount, 2);
    controller.dispose();
    recorder.clear();
  });
  for (final logical in [false, true]) {
    test(
        'real SDK callback${logical ? ' via logical routing' : ''} measures only actual send and ignores no-op',
        () async {
      var now = 0;
      final records = <PerformanceRecord>[];
      final recorder = PerformanceTraceRecorder(
          enabled: () => true, clockUs: () => now, onRecord: records.add);
      final client = OutgoingRetryClient();
      final room = RetryRoom(client: client)..pending = Completer<String?>();
      client.room = room;
      final timeline = RetryTimeline();
      room.timeline = timeline;
      timeline.events
          .add(RetryEvent(room, timeline, id: 'private-event', minute: 1));
      final owner = MatrixSdkE2eeClient(client,
          homeserver: Uri.parse('https://test'),
          readContinuityMetadata: (active) async =>
              MatrixClientContinuityMetadata(
                  isLoggedIn: true,
                  userId: active.userID,
                  deviceId: active.deviceID,
                  ed25519Fingerprint: 'fixture',
                  databaseGeneration: 'fixture'));
      final lease = await owner.openRoomLease(room.id);
      final primary = await lease.openRoomTimeline(onUpdate: () {});
      final capability = logical
          ? LogicalConversationTimelineCapability(
              primaryRoomId: room.id,
              primary: primary,
              sources: {room.id: primary})
          : primary;
      final controller = RoomTimelineController(
          MatrixRoomTimelineAdapter(capability),
          performanceRecorder: recorder);
      if (logical) {
        await expectLater(controller.retry('missing'), throwsStateError);
      } else {
        await controller.retry('missing');
      }
      expect(records, isEmpty);
      final retry = controller.retry('private-event');
      await Future<void>.delayed(Duration.zero);
      expect(room.sends, hasLength(1));
      expect(records, isEmpty);
      controller.dispose();
      now = 23000;
      room.pending!.complete(r'$fixture');
      await retry;
      expect(records, hasLength(1));
      expect(
          records.single.betweenMs(PerformanceStage.matrixSendStart,
              PerformanceStage.matrixSendFinish),
          23);
      expect(records.single.stagesUs.containsKey(PerformanceStage.ack), isTrue);
      await lease.cancel();
      recorder.clear();
    });
  }
  for (final fail in [false, true]) {
    test(
        'SDK attempt beyond five minutes reports only its actual ${fail ? 'failure' : 'success'}',
        () {
      fakeAsync((clock) {
        final records = <PerformanceRecord>[];
        final observations = <PerformanceTraceObservation>[];
        final recorder = PerformanceTraceRecorder(
            enabled: () => true,
            clockUs: () => clock.elapsed.inMicroseconds,
            automaticObservations: true,
            onRecord: records.add,
            onObservation: observations.add);
        final held = Completer<void>();
        final adapter = RetryFailureAdapter()
          ..heldRetry = held
          ..failure = fail ? TimeoutException('private') : null;
        final controller =
            RoomTimelineController(adapter, performanceRecorder: recorder);
        Object? failure;
        var completed = false;
        controller.retry('private').then<void>((_) {
          completed = true;
        }, onError: (Object error) {
          failure = error;
          completed = true;
        });
        clock.flushMicrotasks();
        final root = recorder.activeObservations().single.operationId;
        clock.elapse(const Duration(minutes: 5, seconds: 1));
        expect(completed, isFalse);
        expect(records, isEmpty,
            reason: 'observation expiry is not waitingNetwork settlement');
        expect(recorder.activeCount, 0);
        expect(
            observations
                .any((o) => o.kind == PerformanceObservationKind.expired),
            isTrue);
        held.complete();
        clock.flushMicrotasks();
        expect(completed, isTrue);
        expect(failure, fail ? isA<TimeoutException>() : isNull);
        expect(records, hasLength(1));
        expect(records.single.operationId, root);
        expect(records.single.result,
            fail ? PerformanceResult.failed : PerformanceResult.success);
        controller.dispose();
        recorder.clear();
        expect(clock.pendingTimers, isEmpty);
      });
    });
  }
  test('diagnostic record callback cannot change SDK success', () async {
    final recorder = PerformanceTraceRecorder(
        enabled: () => true,
        onRecord: (_) => throw StateError('diagnostic observer'));
    final adapter = RetryFailureAdapter();
    final controller =
        RoomTimelineController(adapter, performanceRecorder: recorder);
    await controller.retry('private');
    expect(adapter.retryCalls, 1);
    controller.dispose();
    recorder.clear();
  });
  test('diagnostic record callback preserves the original SDK failure',
      () async {
    final recorder = PerformanceTraceRecorder(
        enabled: () => true,
        onRecord: (_) => throw StateError('diagnostic observer'));
    final adapter = RetryFailureAdapter()
      ..failure = TimeoutException('private');
    final controller =
        RoomTimelineController(adapter, performanceRecorder: recorder);
    await expectLater(
        controller.retry('private'), throwsA(isA<TimeoutException>()));
    expect(adapter.retryCalls, 1);
    controller.dispose();
    recorder.clear();
  });
  test(
      'throwing stage and completion clock cannot stop the real SDK send or cleanup',
      () async {
    var clockFails = false;
    final recorder = PerformanceTraceRecorder(
        enabled: () => true,
        clockUs: () {
          if (clockFails) throw StateError('diagnostic clock');
          clockFails = true;
          return 0;
        });
    final client = OutgoingRetryClient();
    final room = RetryRoom(client: client);
    client.room = room;
    final timeline = RetryTimeline();
    room.timeline = timeline;
    timeline.events
        .add(RetryEvent(room, timeline, id: 'private-event', minute: 1));
    final owner = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://test'),
        readContinuityMetadata: (active) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: true,
                userId: active.userID,
                deviceId: active.deviceID,
                ed25519Fingerprint: 'fixture',
                databaseGeneration: 'fixture'));
    final lease = await owner.openRoomLease(room.id);
    final capability = await lease.openRoomTimeline(onUpdate: () {});
    final controller = RoomTimelineController(
        MatrixRoomTimelineAdapter(capability),
        performanceRecorder: recorder);
    await controller.retry('private-event');
    expect(room.sends, hasLength(1));
    expect(recorder.activeCount, 0);
    clockFails = false;
    controller.dispose();
    await lease.cancel();
    recorder.clear();
  });
  test('throwing factory cannot stop the real SDK send', () async {
    final client = OutgoingRetryClient();
    final room = RetryRoom(client: client);
    client.room = room;
    final timeline = RetryTimeline();
    room.timeline = timeline;
    timeline.events
        .add(RetryEvent(room, timeline, id: 'private-event', minute: 1));
    final owner = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://test'),
        readContinuityMetadata: (active) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: true,
                userId: active.userID,
                deviceId: active.deviceID,
                ed25519Fingerprint: 'fixture',
                databaseGeneration: 'fixture'));
    final lease = await owner.openRoomLease(room.id);
    final capability = await lease.openRoomTimeline(onUpdate: () {});
    await (capability as RoomRetryDiagnostics).retryWithDiagnostics(
        'private-event', () => throw StateError('diagnostic factory'));
    expect(room.sends, hasLength(1));
    await lease.cancel();
  });
  test('capacity eviction releases SDK lease without inventing waitingNetwork',
      () async {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
        enabled: () => true, activeCapacity: 1, onRecord: records.add);
    final one = Completer<void>();
    final two = Completer<void>();
    final adapter = RetryFailureAdapter()..heldRetry = one;
    final controller =
        RoomTimelineController(adapter, performanceRecorder: recorder);
    final first = controller.retry('private-one');
    adapter.heldRetry = two;
    final second = controller.retry('private-two');
    expect(records, isEmpty);
    expect(recorder.activeCount, 1);
    one.complete();
    two.complete();
    await Future.wait([first, second]);
    expect(records, hasLength(1));
    expect(records.single.result, PerformanceResult.success);
    controller.dispose();
    recorder.clear();
  });
}
