import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/sound_type.dart';
import 'package:liuhetong_mobile/features/matrix/call_alerts.dart';
import 'package:liuhetong_mobile/features/matrix/call_controller.dart';
import 'package:liuhetong_mobile/features/matrix/call_diagnostics.dart';

import 'call_backend_test_defaults.dart';

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

base class FakeCallBackend with CallBackendTestDefaults implements CallBackend {
  final events = StreamController<CallBackendEvent>.broadcast();
  bool safeRoom = true;
  bool activeSession = true;
  bool failAccept = false;
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
  bool get hasActiveSession => activeSession;

  /// Task F：拨出验证的单一来源必须与 [safeRoom] 一致。
  @override
  bool get fakeSafeRoom => safeRoom;
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
  Future<void> accept() async {
    if (failAccept) throw StateError('answer negotiation failed');
    accepts++;
  }

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

final class CameraBackend extends FakeCallBackend implements CallCameraBackend {
  final cameraRequests = <bool>[];
  bool cameraEnabled = true;
  bool failCamera = false;
  Completer<void>? cameraBarrier;
  @override
  Future<void> setCameraEnabled(bool enabled) async {
    cameraRequests.add(enabled);
    await cameraBarrier?.future;
    if (failCamera) throw StateError('camera unavailable');
    cameraEnabled = enabled;
  }
}

void main() {
  test('outgoing identity survives failure retry and rejects mismatched peer',
      () async {
    final backend = CameraBackend()..activeSession = false;
    final calls = CallController(
        backend: backend,
        permissions: FakeCallPermissions(),
        alerts: RecordingCallAlerts());
    const identity = CallIdentity(
        matrixUserId: '@alice:example.test',
        displayName: 'Alice remark',
        fallbackSeed: 'alice',
        avatarUrl: 'https://example.test/alice');
    await calls.start(
        roomId: '!dm:example.test',
        matrixUserId: identity.matrixUserId,
        type: CallMediaType.video,
        identity: identity);
    expect(calls.state.identity, identity);
    calls.state = calls.state.copyWith(phase: CallPhase.failed);
    await calls.retryAfterFailure();
    expect(calls.state.identity, identity);
    await expectLater(
        calls.start(
            roomId: '!dm:example.test',
            matrixUserId: '@bob:example.test',
            type: CallMediaType.video,
            identity: identity),
        throwsArgumentError);
    expect(calls.state.identity, identity);
    calls.dispose();
  });

  test('camera quick taps converge while audio stays untouched', () async {
    final backend = CameraBackend()..cameraBarrier = Completer<void>();
    final calls = CallController(
        backend: backend,
        permissions: FakeCallPermissions(),
        alerts: RecordingCallAlerts());
    await calls.start(
        roomId: '!dm:example.test',
        matrixUserId: '@alice:example.test',
        type: CallMediaType.video);
    final first = calls.toggleCamera();
    final second = calls.toggleCamera();
    expect(calls.state.cameraEnabled, isTrue);
    backend.cameraBarrier!.complete();
    await Future.wait([first, second]);
    expect(backend.cameraRequests, [false, true]);
    expect(calls.state.cameraEnabled, isTrue);
    expect(calls.state.cameraChanging, isFalse);
    expect(backend.muted, isNull);
    calls.dispose();
  });

  test(
      'camera failure keeps actual state and permits retry; end fences completion',
      () async {
    final backend = CameraBackend()..failCamera = true;
    final calls = CallController(
        backend: backend,
        permissions: FakeCallPermissions(),
        alerts: RecordingCallAlerts());
    await calls.start(
        roomId: '!dm:example.test',
        matrixUserId: '@alice:example.test',
        type: CallMediaType.video);
    await calls.toggleCamera();
    expect(calls.state.cameraEnabled, isTrue);
    expect(calls.state.message, contains('失败'));
    backend.failCamera = false;
    await calls.toggleCamera();
    expect(calls.state.cameraEnabled, isFalse);
    backend.cameraBarrier = Completer<void>();
    final pending = calls.toggleCamera();
    await calls.hangup();
    backend.cameraBarrier!.complete();
    await pending;
    expect(calls.state.phase, CallPhase.ended);
    expect(calls.state.cameraChanging, isFalse);
    expect(calls.state.cameraEnabled, isFalse);
    await calls.toggleCamera();
    expect(backend.cameraRequests, [false, false, true]);
    calls.dispose();
  });

  test('duplicate connected events keep the original duration origin',
      () async {
    final backend = FakeCallBackend();
    var clock = DateTime(2026, 10, 5, 12);
    final controller = CallController(
        backend: backend,
        permissions: FakeCallPermissions(),
        alerts: RecordingCallAlerts(),
        now: () => clock);
    await controller.start(
        roomId: '!dm:example.test',
        matrixUserId: '@alice:example.test',
        type: CallMediaType.video);
    backend.events.add(const CallBackendEvent.connected());
    await Future<void>.delayed(Duration.zero);
    final origin = controller.state.connectedAt;
    clock = clock.add(const Duration(seconds: 25));
    backend.events.add(const CallBackendEvent.connected());
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.connectedAt, origin);
    controller.dispose();
  });
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

  Future<CallController> ringingIncomingCall(
    FakeCallBackend backend, {
    RecordingCallAlerts? alerts,
    CallDiagnostics? diagnostics,
    Duration connectTimeout = const Duration(seconds: 45),
  }) async {
    final controller = CallController(
      backend: backend,
      permissions: FakeCallPermissions(),
      alerts: alerts ?? RecordingCallAlerts(),
      diagnostics: diagnostics,
      connectTimeout: connectTimeout,
    );
    backend.events.add(const CallBackendEvent.incoming(
      roomId: '!dm:example.test',
      matrixUserId: '@alice:example.test',
      type: CallMediaType.audio,
    ));
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.phase, CallPhase.ringing);
    return controller;
  }

  test('accept signaling failure enters failed state instead of hanging',
      () async {
    final backend = FakeCallBackend()..failAccept = true;
    final alerts = RecordingCallAlerts();
    final controller = await ringingIncomingCall(backend, alerts: alerts);

    await controller.accept();
    expect(controller.state.phase, CallPhase.failed, reason: '接听信令异常不得裸抛或卡在响铃');
    expect(controller.state.message, '接听失败，请重试');
    expect(alerts.stopped, greaterThanOrEqualTo(1), reason: '失败即停铃');
    expect(backend.hangups, 0, reason: '失败态不自动挂断，交给重试/关闭');
    controller.dispose();
  });

  test('accept transitions to connecting and times out when ICE never lands',
      () async {
    final backend = FakeCallBackend();
    final controller = await ringingIncomingCall(
      backend,
      connectTimeout: const Duration(milliseconds: 60),
    );

    await controller.accept();
    expect(controller.state.phase, CallPhase.connecting,
        reason: '接听后等待 ICE 期间应显示连接中，而非继续响铃');

    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(controller.state.phase, CallPhase.failed, reason: 'ICE 超时进入失败态');
    expect(controller.state.message, '接通超时，请重试');
    expect(backend.hangups, 1, reason: '超时后挂断死会话以便重试回拨');
    controller.dispose();
  });

  test('connecting to connected cancels the connect timeout', () async {
    final backend = FakeCallBackend();
    final controller = await ringingIncomingCall(
      backend,
      connectTimeout: const Duration(milliseconds: 60),
    );
    await controller.accept();
    backend.events.add(const CallBackendEvent.connected());
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(controller.state.phase, CallPhase.connected,
        reason: '接通后连接超时定时器必须失效');
    expect(backend.hangups, 0);
    controller.dispose();
  });

  test('retry after failure re-accepts while the session is still alive',
      () async {
    final backend = FakeCallBackend()..failAccept = true;
    final controller = await ringingIncomingCall(backend);
    await controller.accept();
    expect(controller.state.phase, CallPhase.failed);

    backend.failAccept = false;
    backend.activeSession = true;
    await controller.retryAfterFailure();
    expect(backend.accepts, 1, reason: '会话存活时重试=再次接听');
    expect(controller.state.phase, CallPhase.connecting);
    controller.dispose();
  });

  test('retry after failure calls back when the session is gone', () async {
    final backend = FakeCallBackend()..failAccept = true;
    final controller = await ringingIncomingCall(
      backend,
      connectTimeout: const Duration(milliseconds: 60),
    );
    await controller.accept(); // 失败（信令）
    backend.activeSession = false; // 会话已被清理/超时挂断
    await controller.retryAfterFailure();
    expect(backend.starts, 1, reason: '会话已死时重试=对同一用户回拨');
    expect(controller.state.phase, CallPhase.ringing, reason: '回拨进入主叫等待');
    controller.dispose();
  });

  test('key-path diagnostics record ui/answer/ice stages', () async {
    final backend = FakeCallBackend();
    final diagnostics = CallDiagnostics(
      now: () => DateTime.fromMillisecondsSinceEpoch(0),
    );
    final controller =
        await ringingIncomingCall(backend, diagnostics: diagnostics);

    expect(diagnostics.has(CallDiagStage.incomingUiShown), isTrue,
        reason: '来电 UI 展示必须埋点');

    await controller.accept();
    expect(diagnostics.has(CallDiagStage.answerTapped), isTrue);

    backend.events.add(const CallBackendEvent.connected());
    await Future<void>.delayed(Duration.zero);
    expect(diagnostics.has(CallDiagStage.iceConnected), isTrue);

    final summary = diagnostics.summary();
    expect(summary, contains('ui→tap='));
    expect(summary, contains('tap→sent='));
    expect(summary, contains('sent→ice='));
    controller.dispose();
  });
}
