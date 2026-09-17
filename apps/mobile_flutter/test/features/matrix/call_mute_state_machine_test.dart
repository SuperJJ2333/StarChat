import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/call_controller.dart';

import 'call_backend_test_defaults.dart';

/// Task M：静音串行化、本地先行、失败回滚。
///
/// 真实媒体链路保持不变：`toggleMute → backend.setMuted →
/// CallSession.setMicrophoneMuted → local audio track enabled=false`。
void main() {
  test('false → true disables the real track; true → false re-enables it',
      () async {
    final backend = _MuteBackend();
    final controller = _controller(backend);
    addTearDown(controller.dispose);
    addTearDown(backend.events.close);
    await _ringAndAccept(backend, controller);

    await controller.toggleMute();
    expect(backend.trackEnabled, isFalse, reason: '真实 audio track 必须被禁用');
    expect(backend.calls, [true]);
    expect(controller.state.muted, isTrue);

    await controller.toggleMute();
    expect(backend.trackEnabled, isTrue);
    expect(backend.calls, [true, false]);
    expect(controller.state.muted, isFalse);
  });

  test('a fast mute/unmute/mute burst converges to the last intent', () async {
    final backend = _MuteBackend()..latency = const Duration(milliseconds: 5);
    final controller = _controller(backend);
    addTearDown(controller.dispose);
    addTearDown(backend.events.close);
    await _ringAndAccept(backend, controller);

    // Two concurrent toggles reading the same stale state used to both send
    // `true`; the serialized desired-state machine must converge.
    final first = controller.toggleMute();
    final second = controller.toggleMute();
    final third = controller.toggleMute();
    await Future.wait([first, second, third]);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(controller.state.muted, isTrue, reason: '三次快速切换后收敛到最后意图');
    expect(backend.trackEnabled, isFalse);
    expect(backend.calls.last, isTrue);
  });

  test('a rapid double toggle lands on unmuted', () async {
    final backend = _MuteBackend()..latency = const Duration(milliseconds: 5);
    final controller = _controller(backend);
    addTearDown(controller.dispose);
    addTearDown(backend.events.close);
    await _ringAndAccept(backend, controller);

    await Future.wait([controller.toggleMute(), controller.toggleMute()]);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(controller.state.muted, isFalse);
    expect(backend.trackEnabled, isTrue);
  });

  test('UI updates before remote metadata signaling completes', () async {
    final backend = _MuteBackend();
    // Local track flips immediately; the remote metadata push is slow.
    backend.metadataLatency = const Duration(milliseconds: 200);
    final controller = _controller(backend);
    addTearDown(controller.dispose);
    addTearDown(backend.events.close);
    await _ringAndAccept(backend, controller);

    final pending = controller.toggleMute();
    await pending;
    expect(controller.state.muted, isTrue,
        reason: '本地 track 成功即更新 UI，不等待 sendSDPStreamMetadataChanged');
    // The slow metadata push is still in flight and has not blocked the UI.
    expect(backend.metadataFailures, 0);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(controller.state.muted, isTrue);
  });

  test('local track failure rolls the UI back', () async {
    final backend = _MuteBackend()..failLocalTrack = true;
    final controller = _controller(backend);
    addTearDown(controller.dispose);
    addTearDown(backend.events.close);
    await _ringAndAccept(backend, controller);

    await controller.toggleMute();
    expect(controller.state.muted, isFalse, reason: '本地失败必须回滚 UI');
    expect(backend.trackEnabled, isTrue);
  });

  test('remote metadata failure keeps the true local muted state', () async {
    final backend = _MuteBackend()..failMetadata = true;
    final controller = _controller(backend);
    addTearDown(controller.dispose);
    addTearDown(backend.events.close);
    await _ringAndAccept(backend, controller);

    await controller.toggleMute();
    expect(controller.state.muted, isTrue, reason: '仅远端元数据失败不得让 UI 谎报未静音');
    expect(backend.trackEnabled, isFalse);
    expect(backend.metadataFailures, 1, reason: '远端元数据失败必须留诊断，不能被吞掉');
  });

  test('mute state is not carried across calls', () async {
    final backend = _MuteBackend();
    final controller = _controller(backend);
    addTearDown(controller.dispose);
    addTearDown(backend.events.close);
    await _ringAndAccept(backend, controller);
    await controller.toggleMute();
    expect(controller.state.muted, isTrue);

    backend.events.add(const CallBackendEvent.incoming(
      roomId: '!dm:test',
      matrixUserId: '@bob:test',
      type: CallMediaType.audio,
    ));
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.muted, isFalse, reason: '新通话从未静音开始');
  });

  test('native mute request maps onto the same desired state', () async {
    final backend = _MuteBackend();
    final controller = _controller(backend);
    addTearDown(controller.dispose);
    addTearDown(backend.events.close);
    await _ringAndAccept(backend, controller);

    // CallKit CXSetMutedCallAction(true) → app_home calls setMuted(true).
    await controller.setMuted(true);
    expect(controller.state.muted, isTrue);
    expect(backend.trackEnabled, isFalse);

    // Repeated identical native actions are idempotent, not a double flip.
    await controller.setMuted(true);
    expect(controller.state.muted, isTrue);
    expect(backend.calls, [true], reason: '重复相同意图不得再次下发');

    await controller.setMuted(false);
    expect(controller.state.muted, isFalse);
    expect(backend.calls, [true, false]);
  });

  test('mute failures are reported to the caller so the UI can react',
      () async {
    final backend = _MuteBackend()..failLocalTrack = true;
    final controller = _controller(backend);
    addTearDown(controller.dispose);
    addTearDown(backend.events.close);
    await _ringAndAccept(backend, controller);
    // setMuted must not throw into the widget layer; it rolls back instead.
    await expectLater(controller.setMuted(true), completes);
    expect(controller.state.muted, isFalse);
  });
}

CallController _controller(_MuteBackend backend) =>
    CallController(backend: backend, permissions: _Permissions());

Future<void> _ringAndAccept(
    _MuteBackend backend, CallController controller) async {
  backend.events.add(const CallBackendEvent.incoming(
    roomId: '!dm:test',
    matrixUserId: '@alice:test',
    type: CallMediaType.audio,
  ));
  await Future<void>.delayed(Duration.zero);
  await controller.accept();
}

final class _Permissions implements CallPermissionGateway {
  @override
  Future<bool> request({required bool video}) async => true;
}

/// 模拟真实链路：本地 track 先翻转，随后（可能失败地）推送远端元数据。
base class _MuteBackend with CallBackendTestDefaults {
  final events = StreamController<CallBackendEvent>.broadcast();
  final calls = <bool>[];
  bool trackEnabled = true;
  bool failLocalTrack = false;
  bool failMetadata = false;
  Duration latency = Duration.zero;
  Duration metadataLatency = Duration.zero;
  int metadataFailures = 0;
  void Function()? metadataFailuresNotifier;

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
  Future<void> accept() async {}
  @override
  Future<void> reject() async {}
  @override
  Future<void> hangup() async {}
  @override
  Future<void> setSpeaker(bool value) async {}
  @override
  Future<void> switchCamera() async {}

  @override
  Future<void> setMuted(bool value) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (failLocalTrack) {
      // Local track operations surface as a failure so the UI rolls back.
      throw StateError('local audio track unavailable');
    }
    // Local track flip is the authoritative state and completes immediately,
    // mirroring CallSession.setMicrophoneMuted.
    trackEnabled = !value;
    calls.add(value);
    // Remote SDP stream metadata is a best-effort side channel pushed off the
    // awaited path: the local track is already muted, so a failure here must
    // NOT be reported as a local failure.
    unawaited(_publishMetadata());
  }

  Future<void> _publishMetadata() async {
    if (metadataLatency > Duration.zero) {
      await Future<void>.delayed(metadataLatency);
    }
    if (failMetadata) {
      metadataFailures++;
      metadataFailuresNotifier?.call();
    }
  }
}
