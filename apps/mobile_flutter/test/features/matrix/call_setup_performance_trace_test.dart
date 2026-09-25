import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/sound_type.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';
import 'package:liuhetong_mobile/features/matrix/call_alerts.dart';
import 'package:liuhetong_mobile/features/matrix/call_controller.dart';

import 'call_backend_test_defaults.dart';

final class _Permissions implements CallPermissionGateway {
  bool throwOnRequest = false;

  @override
  Future<bool> request({required bool video}) async {
    if (throwOnRequest) throw StateError('permission unavailable');
    return true;
  }
}

final class _SilentAlerts implements CallAlertDriver {
  @override
  Future<void> startRingtone(SoundType ringtone) async {}
  @override
  Future<void> stopRingtone() async {}
  @override
  Future<void> vibrate() async {}
}

final class _Backend with CallBackendTestDefaults implements CallBackend {
  final events = StreamController<CallBackendEvent>.broadcast();
  final answer = Completer<void>();
  bool throwOnVerify = false;

  @override
  Future<VerifiedCallTarget?> verifyStartTarget(
      String roomId, String matrixUserId) {
    if (throwOnVerify) throw StateError('verification unavailable');
    return super.verifyStartTarget(roomId, matrixUserId);
  }

  @override
  Stream<CallBackendEvent> get callEvents => events.stream;
  @override
  bool get hasActiveSession => true;
  @override
  Future<bool> isEncryptedDirectRoom(
          String roomId, String matrixUserId) async =>
      true;
  @override
  Future<void> start(
      String roomId, String matrixUserId, CallMediaType type) async {}
  @override
  Future<void> accept() => answer.future;
  @override
  Future<void> reject() async {}
  @override
  Future<void> hangup() async {}
  @override
  Future<void> setMuted(bool value) async {}
  @override
  Future<void> setSpeaker(bool value) async {}
  @override
  Future<void> switchCamera() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('outgoing answer and ICE connection share one setup operation',
      () async {
    var nowUs = 0;
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      clockUs: () => nowUs,
      onRecord: records.add,
    );
    final backend = _Backend();
    final controller = CallController(
      backend: backend,
      permissions: _Permissions(),
      alerts: CallAlerts(driver: _SilentAlerts()),
      performanceRecorder: recorder,
    );

    await controller.start(
      roomId: '!private:example.test',
      matrixUserId: '@private:example.test',
      type: CallMediaType.audio,
    );
    expect(recorder.activeCount, 1);
    nowUs = 230000;
    backend.events.add(const CallBackendEvent.signalingReady());
    await Future<void>.delayed(Duration.zero);
    nowUs = 610000;
    backend.events.add(const CallBackendEvent.connected());
    await Future<void>.delayed(Duration.zero);

    expect(records, hasLength(1));
    final record = records.single;
    expect(record.operation, PerformanceOperationType.callSetup);
    expect(record.result, PerformanceResult.success);
    expect(record.totalMs, 610);
    expect(record.stagesUs.keys, [
      PerformanceStage.callStart,
      PerformanceStage.signalingReady,
      PerformanceStage.iceConnected,
      PerformanceStage.callConnected,
    ]);
    expect(
        record.betweenMs(
            PerformanceStage.callStart, PerformanceStage.signalingReady),
        230);
    expect(
        record.betweenMs(
            PerformanceStage.signalingReady, PerformanceStage.iceConnected),
        380);
    expect(record.stagesUs.containsKey(PerformanceStage.iceGathering), isFalse);
    expect(record.stagesUs.containsKey(PerformanceStage.mediaFirstPacket),
        isFalse);
    expect(record.toJson().toString(), isNot(contains('private')));
    expect(recorder.activeCount, 0);

    controller.dispose();
    await backend.events.close();
  });

  test('incoming answer starts at tap, and cancelled setup is released',
      () async {
    var nowUs = 0;
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      clockUs: () => nowUs,
      onRecord: records.add,
    );
    final backend = _Backend();
    final controller = CallController(
      backend: backend,
      permissions: _Permissions(),
      alerts: CallAlerts(driver: _SilentAlerts()),
      performanceRecorder: recorder,
    );
    backend.events.add(const CallBackendEvent.incoming(
      roomId: '!private:example.test',
      matrixUserId: '@private:example.test',
      type: CallMediaType.audio,
    ));
    await Future<void>.delayed(Duration.zero);
    nowUs = 100000;
    final accepting = controller.accept();
    await Future<void>.delayed(Duration.zero);
    expect(recorder.activeCount, 1);
    nowUs = 330000;
    backend.answer.complete();
    await accepting;
    backend.events.add(const CallBackendEvent.signalingReady());
    await Future<void>.delayed(Duration.zero);
    nowUs = 410000;
    await controller.hangup();

    expect(records, hasLength(1));
    expect(records.single.result, PerformanceResult.cancelled);
    expect(records.single.totalMs, 310);
    expect(records.single.stagesUs.keys, [
      PerformanceStage.callStart,
      PerformanceStage.signalingReady,
    ]);
    expect(recorder.activeCount, 0);
    controller.dispose();
    await backend.events.close();
  });

  test('disposing an incomplete setup releases the active trace', () async {
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
    );
    final backend = _Backend();
    final controller = CallController(
      backend: backend,
      permissions: _Permissions(),
      alerts: CallAlerts(driver: _SilentAlerts()),
      performanceRecorder: recorder,
    );
    await controller.start(
      roomId: '!private:example.test',
      matrixUserId: '@private:example.test',
      type: CallMediaType.audio,
    );
    expect(recorder.activeCount, 1);
    controller.dispose();
    expect(recorder.activeCount, 0);
    await backend.events.close();
  });

  test('verification and permission exceptions close setup traces', () async {
    for (final verificationFailure in [true, false]) {
      final records = <PerformanceRecord>[];
      final recorder = PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true),
        onRecord: records.add,
      );
      final backend = _Backend()..throwOnVerify = verificationFailure;
      final permissions = _Permissions()..throwOnRequest = !verificationFailure;
      final controller = CallController(
        backend: backend,
        permissions: permissions,
        alerts: CallAlerts(driver: _SilentAlerts()),
        performanceRecorder: recorder,
      );
      await expectLater(
        controller.start(
          roomId: '!private:example.test',
          matrixUserId: '@private:example.test',
          type: CallMediaType.audio,
        ),
        throwsStateError,
      );
      expect(recorder.activeCount, 0);
      expect(records, hasLength(1));
      expect(records.single.result, PerformanceResult.failed);
      controller.dispose();
      await backend.events.close();
    }
  });
}
