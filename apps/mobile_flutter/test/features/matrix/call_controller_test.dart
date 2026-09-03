import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/sound_type.dart';
import 'package:liuhetong_mobile/features/matrix/call_alerts.dart';
import 'package:liuhetong_mobile/features/matrix/call_controller.dart';

final class FakeCallPermissions implements CallPermissionGateway {
  bool allowed = true;
  int requests = 0;
  @override
  Future<bool> request({required bool video}) async {
    requests++;
    return allowed;
  }
}

final class RecordingCallAlerts extends CallAlerts {
  RecordingCallAlerts() : super(driver: _NoopDriver());
  int started = 0;
  int stopped = 0;
  final ringtones = <SoundType>[];

  @override
  void start(SoundType ringtone) {
    ringtones.add(ringtone);
    started++;
  }

  @override
  void stop() => stopped++;
}

final class RecordingCallSoundCues implements CallSoundCues {
  int connectedCount = 0;
  int endedCount = 0;

  @override
  void connected() => connectedCount++;

  @override
  void ended() => endedCount++;
}

final class _NoopDriver implements CallAlertDriver {
  @override
  Future<void> startRingtone(SoundType ringtone) async {}

  @override
  Future<void> stopRingtone() async {}

  @override
  Future<void> vibrate() async {}
}

final class FakeCallBackend implements CallBackend {
  final events = StreamController<CallBackendEvent>.broadcast();
  bool safeRoom = true;
  int starts = 0;
  int accepts = 0;
  int rejects = 0;
  int hangups = 0;
  bool? muted;
  bool? speaker;
  int cameraSwitches = 0;

  @override
  Stream<CallBackendEvent> get callEvents => events.stream;
  @override
  Future<bool> isEncryptedDirectRoom(
          String roomId, String matrixUserId) async =>
      safeRoom;
  @override
  Future<void> start(
      String roomId, String matrixUserId, CallMediaType type) async {
    starts++;
  }

  @override
  Future<void> accept() async => accepts++;
  @override
  Future<void> reject() async => rejects++;
  @override
  Future<void> hangup() async => hangups++;
  @override
  Future<void> setMuted(bool value) async => muted = value;
  @override
  Future<void> setSpeaker(bool value) async => speaker = value;
  @override
  Future<void> switchCamera() async => cameraSwitches++;
}

void main() {
  test('outgoing encrypted call transitions and controls media', () async {
    final backend = FakeCallBackend();
    final permissions = FakeCallPermissions();
    final alerts = RecordingCallAlerts();
    final soundCues = RecordingCallSoundCues();
    final controller = CallController(
      backend: backend,
      permissions: permissions,
      alerts: alerts,
      soundCues: soundCues,
    );

    final start = controller.start(
      roomId: '!dm:example.test',
      matrixUserId: '@alice:example.test',
      type: CallMediaType.video,
    );
    expect(controller.state.phase, CallPhase.requestingPermission);
    await start;
    expect(controller.state.phase, CallPhase.ringing);
    expect(alerts.started, 1, reason: '主叫等待期间维持铃声+震动提醒');
    expect(alerts.ringtones.last, SoundType.callOutgoing,
        reason: '主叫使用呼叫等待音（PRD §5）');
    backend.events.add(const CallBackendEvent.connected());
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.phase, CallPhase.connected);
    expect(alerts.stopped, greaterThanOrEqualTo(1), reason: '接通即停铃');
    expect(soundCues.connectedCount, 1, reason: '接通播放确认音（PRD §5）');
    // 视频通话接通默认打开免提（微信语义）。
    expect(backend.speaker, isTrue);
    expect(controller.state.speaker, isTrue);
    expect(controller.state.connectedAt, isNotNull);

    await controller.toggleMute();
    await controller.toggleSpeaker();
    await controller.switchCamera();
    expect(backend.muted, isTrue);
    expect(backend.speaker, isFalse);
    expect(backend.cameraSwitches, 1);
    await controller.hangup();
    expect(controller.state.phase, CallPhase.ended);
    expect(backend.hangups, 1);
    expect(soundCues.endedCount, 1, reason: '结束播放结束音（PRD §5）');
    controller.dispose();
  });

  test('permission denial and unsafe room fail before call signaling',
      () async {
    final deniedBackend = FakeCallBackend();
    final deniedPermissions = FakeCallPermissions()..allowed = false;
    final denied = CallController(
      backend: deniedBackend,
      permissions: deniedPermissions,
      alerts: RecordingCallAlerts(),
    );
    await denied.start(
      roomId: '!dm:example.test',
      matrixUserId: '@alice:example.test',
      type: CallMediaType.audio,
    );
    expect(denied.state.phase, CallPhase.permissionDenied);
    expect(deniedBackend.starts, 0);

    final unsafeBackend = FakeCallBackend()..safeRoom = false;
    final permissions = FakeCallPermissions();
    final unsafe = CallController(
      backend: unsafeBackend,
      permissions: permissions,
      alerts: RecordingCallAlerts(),
    );
    await expectLater(
      unsafe.start(
        roomId: '!group:example.test',
        matrixUserId: '@alice:example.test',
        type: CallMediaType.audio,
      ),
      throwsStateError,
    );
    expect(permissions.requests, 0);
    expect(unsafeBackend.starts, 0);
    denied.dispose();
    unsafe.dispose();
  });

  test('incoming call can be accepted or rejected', () async {
    final backend = FakeCallBackend();
    final alerts = RecordingCallAlerts();
    final controller = CallController(
      backend: backend,
      permissions: FakeCallPermissions(),
      alerts: alerts,
    );
    backend.events.add(const CallBackendEvent.incoming(
      roomId: '!dm:example.test',
      matrixUserId: '@alice:example.test',
      type: CallMediaType.audio,
    ));
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.phase, CallPhase.ringing);
    expect(alerts.ringtones.last, SoundType.callVoiceIncoming,
        reason: '被叫语音来电使用语音铃声（PRD §9）');
    await controller.accept();
    expect(backend.accepts, 1);
    backend.events.add(const CallBackendEvent.connected());
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.phase, CallPhase.connected);

    backend.events.add(const CallBackendEvent.incoming(
      roomId: '!dm:example.test',
      matrixUserId: '@alice:example.test',
      type: CallMediaType.video,
    ));
    await Future<void>.delayed(Duration.zero);
    expect(alerts.ringtones.last, SoundType.callVideoIncoming,
        reason: '被叫视频来电使用视频铃声（PRD §10）');
    await controller.reject();
    expect(backend.rejects, 1);
    expect(controller.state.phase, CallPhase.ended);
    controller.dispose();
  });

  test('network interruption ends without retrying signaling', () async {
    final backend = FakeCallBackend();
    final controller = CallController(
      backend: backend,
      permissions: FakeCallPermissions(),
      alerts: RecordingCallAlerts(),
    );
    backend.events.add(const CallBackendEvent.networkInterrupted());
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.phase, CallPhase.ended);
    expect(controller.state.message, contains('网络'));
    controller.dispose();
  });

  test('outgoing call auto-cancels when nobody answers within the timeout',
      () async {
    final backend = FakeCallBackend();
    final alerts = RecordingCallAlerts();
    final controller = CallController(
      backend: backend,
      permissions: FakeCallPermissions(),
      alerts: alerts,
      ringTimeout: const Duration(milliseconds: 60),
    );
    await controller.start(
      roomId: '!dm:example.test',
      matrixUserId: '@alice:example.test',
      type: CallMediaType.audio,
    );
    expect(controller.state.phase, CallPhase.ringing);
    expect(backend.hangups, 0);

    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(controller.state.phase, CallPhase.ended, reason: '超时自动取消');
    expect(controller.state.message, '对方无应答，已取消');
    expect(backend.hangups, 1, reason: '超时后自动挂断');
    expect(alerts.stopped, greaterThanOrEqualTo(1), reason: '取消即停铃');
    controller.dispose();
  });

  test('accepting before the ring timeout cancels the auto-hangup', () async {
    final backend = FakeCallBackend();
    final controller = CallController(
      backend: backend,
      permissions: FakeCallPermissions(),
      alerts: RecordingCallAlerts(),
      ringTimeout: const Duration(milliseconds: 80),
    );
    await controller.start(
      roomId: '!dm:example.test',
      matrixUserId: '@alice:example.test',
      type: CallMediaType.audio,
    );
    backend.events.add(const CallBackendEvent.connected());
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(controller.state.phase, CallPhase.connected, reason: '接通后超时定时器必须失效');
    expect(backend.hangups, 0);
    controller.dispose();
  });

  test('call duration formatting', () {
    expect(formatCallDuration(Duration.zero), '00:00');
    expect(formatCallDuration(const Duration(seconds: 65)), '01:05');
    expect(formatCallDuration(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '1:02:03');
  });
}
