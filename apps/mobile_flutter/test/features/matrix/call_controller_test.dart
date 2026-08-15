import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
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
    final controller =
        CallController(backend: backend, permissions: permissions);

    final start = controller.start(
      roomId: '!dm:example.test',
      matrixUserId: '@alice:example.test',
      type: CallMediaType.video,
    );
    expect(controller.state.phase, CallPhase.requestingPermission);
    await start;
    expect(controller.state.phase, CallPhase.ringing);
    backend.events.add(const CallBackendEvent.connected());
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.phase, CallPhase.connected);

    await controller.toggleMute();
    await controller.toggleSpeaker();
    await controller.switchCamera();
    expect(backend.muted, isTrue);
    expect(backend.speaker, isTrue);
    expect(backend.cameraSwitches, 1);
    await controller.hangup();
    expect(controller.state.phase, CallPhase.ended);
    expect(backend.hangups, 1);
  });

  test('permission denial and unsafe room fail before call signaling',
      () async {
    final deniedBackend = FakeCallBackend();
    final deniedPermissions = FakeCallPermissions()..allowed = false;
    final denied =
        CallController(backend: deniedBackend, permissions: deniedPermissions);
    await denied.start(
      roomId: '!dm:example.test',
      matrixUserId: '@alice:example.test',
      type: CallMediaType.audio,
    );
    expect(denied.state.phase, CallPhase.permissionDenied);
    expect(deniedBackend.starts, 0);

    final unsafeBackend = FakeCallBackend()..safeRoom = false;
    final permissions = FakeCallPermissions();
    final unsafe =
        CallController(backend: unsafeBackend, permissions: permissions);
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
  });

  test('incoming call can be accepted or rejected', () async {
    final backend = FakeCallBackend();
    final controller = CallController(
      backend: backend,
      permissions: FakeCallPermissions(),
    );
    backend.events.add(const CallBackendEvent.incoming(
      roomId: '!dm:example.test',
      matrixUserId: '@alice:example.test',
      type: CallMediaType.audio,
    ));
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.phase, CallPhase.ringing);
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
    await controller.reject();
    expect(backend.rejects, 1);
    expect(controller.state.phase, CallPhase.ended);
  });

  test('network interruption ends without retrying signaling', () async {
    final backend = FakeCallBackend();
    final controller = CallController(
      backend: backend,
      permissions: FakeCallPermissions(),
    );
    backend.events.add(const CallBackendEvent.networkInterrupted());
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.phase, CallPhase.ended);
    expect(controller.state.message, contains('网络'));
  });
}
