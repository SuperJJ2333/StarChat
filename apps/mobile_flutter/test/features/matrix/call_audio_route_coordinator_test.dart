import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/call_audio_route_coordinator.dart';
import 'package:liuhetong_mobile/features/matrix/call_controller.dart';

import 'call_backend_test_defaults.dart';

/// 唯一音频路由所有者（Task I）：
/// - Matrix CallSession 不再按 CallType 私自改 speaker；
/// - 用户手动选择在 stream 重建 / ICE restart / connected 之后不得被覆盖；
/// - 自动策略只在用户**没有**明确选择时生效。
void main() {
  group('CallAudioRouteCoordinator 自动策略', () {
    test('语音默认听筒；视频默认免提', () async {
      final voice = _RouteSink();
      final voiceRoute = CallAudioRouteCoordinator(apply: voice.apply);
      await voiceRoute.applyPreMediaRoute(CallMediaType.audio);
      expect(voice.applied, [false], reason: '语音默认听筒（speaker=false）');

      final video = _RouteSink();
      final videoRoute = CallAudioRouteCoordinator(apply: video.apply);
      await videoRoute.applyPreMediaRoute(CallMediaType.video);
      expect(video.applied, [false], reason: '媒体建立前先清除上一通遗留的免提状态');

      await videoRoute.preferForConnected(CallMediaType.video);
      expect(video.applied, [false, true], reason: '视频接通默认免提');
      expect(videoRoute.speaker, isTrue);

      // 语音：状态未变化时不重复下发（幂等），但状态必须是听筒。
      await voiceRoute.preferForConnected(CallMediaType.audio);
      expect(voiceRoute.speaker, isFalse, reason: '语音接通保持听筒');
      expect(voice.applied, [false], reason: '状态未变化时保持幂等');
    });

    test('未变化的状态不重复下发平台调用（reapply 为显式重申）', () async {
      final backend = _RouteSink();
      final route = CallAudioRouteCoordinator(apply: backend.apply);
      await route.applyPreMediaRoute(CallMediaType.audio);
      await route.preferForConnected(CallMediaType.audio);
      expect(backend.applied, [false], reason: '状态未变化时保持幂等');

      // reapply 是显式重申（Activity/场景重建后原生路由可能丢失），
      // 允许重复下发同值；策略计算本身仍幂等。
      await route.reapply();
      expect(backend.applied, [false, false]);
    });

    test('用户手动选择在 connected / 重建 / ICE restart 后保持', () async {
      final backend = _RouteSink();
      final route = CallAudioRouteCoordinator(apply: backend.apply);
      await route.applyPreMediaRoute(CallMediaType.audio);

      // 用户点“免提”。
      await route.toggleSpeaker(CallMediaType.audio);
      expect(route.speaker, isTrue);
      expect(route.hasUserPreference, isTrue);

      // 接通、媒体流重建、ICE restart 都不得把选择覆盖回听筒。
      await route.preferForConnected(CallMediaType.audio);
      route.onLocalStreamRecreated();
      await route.reapply();
      await route.applyPreMediaRoute(CallMediaType.audio);
      expect(route.speaker, isTrue, reason: '用户明确选择不得被自动策略覆盖');
      expect(backend.applied.last, isTrue);

      // 语音通话中用户再点一次 → 回到听筒。
      await route.toggleSpeaker(CallMediaType.audio);
      expect(route.speaker, isFalse);
      await route.preferForConnected(CallMediaType.audio);
      expect(route.speaker, isFalse, reason: '显式听筒同样不被视频/接通默认覆盖');
    });

    test('视频通话中用户切回听筒不被 connected 覆盖', () async {
      final backend = _RouteSink();
      final route = CallAudioRouteCoordinator(apply: backend.apply);
      await route.applyPreMediaRoute(CallMediaType.video);
      await route.preferForConnected(CallMediaType.video);
      expect(route.speaker, isTrue);

      // 用户明确选择听筒（不是默认，而是显式覆盖）。
      await route.setSpeaker(false,
          type: CallMediaType.video, markUserPreference: true);
      expect(route.speaker, isFalse);
      await route.preferForConnected(CallMediaType.video);
      expect(route.speaker, isFalse, reason: '用户显式听筒优先于视频免提默认');
      expect(backend.applied.last, isFalse, reason: '自动策略不得把用户选择改回扬声器');
    });

    test('platform failure is surfaced, not silently reported as applied',
        () async {
      final backend = _RouteSink()..fail = true;
      final route = CallAudioRouteCoordinator(apply: backend.apply);
      await expectLater(
        route.applyPreMediaRoute(CallMediaType.video),
        throwsStateError,
      );
      expect(route.appliedSpeaker, isNot(true), reason: '平台调用失败时不得假装已应用');
      await expectLater(
        route.setSpeaker(true, type: CallMediaType.video),
        throwsStateError,
      );
      expect(route.appliedSpeaker, isNot(true));
    });

    test('蓝牙/有线耳机：外部设备在场时不下发扬声器覆盖', () async {
      final backend = _RouteSink();
      final route = CallAudioRouteCoordinator(apply: backend.apply);
      // 外部设备已连接 → 系统路由优先，协调器不得强制切回扬声器。
      await route.setExternalRouteActive(true);
      await route.applyPreMediaRoute(CallMediaType.audio);
      expect(route.speaker, isFalse);
      await route.preferForConnected(CallMediaType.audio);
      expect(route.speaker, isFalse, reason: '外部设备在场不得强制扬声器');
      for (final value in backend.applied) {
        expect(value, isFalse, reason: '外部设备在场时不允许任何 speaker=true 下发');
      }

      // 视频通话在外部设备在场时同样不抢路由（用户可自行切换）。
      await route.preferForConnected(CallMediaType.video);
      expect(route.speaker, isFalse, reason: '蓝牙/有线耳机不被无条件扬声器覆盖');
    });
  });

  group('CallController 与路由所有者接线', () {
    test('toggleSpeaker 经协调器且状态本地先行', () async {
      final backend = _ControllerBackend();
      final route = CallAudioRouteCoordinator(apply: backend.applyRoute);
      final controller = CallController(
        backend: backend,
        permissions: _Permissions(),
        audioRoute: route,
      );
      addTearDown(controller.dispose);
      addTearDown(backend.events.close);

      backend.events.add(const CallBackendEvent.incoming(
        roomId: '!dm:test',
        matrixUserId: '@alice:test',
        type: CallMediaType.audio,
      ));
      await Future<void>.delayed(Duration.zero);
      await controller.accept();
      await controller.toggleSpeaker();
      expect(controller.state.speaker, isTrue);
      expect(route.speaker, isTrue);
      expect(route.hasUserPreference, isTrue,
          reason: '点击免提必须记为用户选择，否则会被自动策略覆盖');
      expect(backend.routeCalls.last, isTrue);

      // 接通事件不得把用户的选择改回去。
      backend.events.add(const CallBackendEvent.connected());
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.speaker, isTrue);
      expect(backend.routeCalls.last, isTrue);
    });

    test('controller 不再直接调用 backend.setSpeaker（唯一所有者）', () async {
      final backend = _ControllerBackend();
      final route = CallAudioRouteCoordinator(apply: backend.applyRoute);
      final controller = CallController(
        backend: backend,
        permissions: _Permissions(),
        audioRoute: route,
      );
      addTearDown(controller.dispose);
      addTearDown(backend.events.close);
      await controller.start(
        roomId: '!dm:test',
        matrixUserId: '@alice:test',
        type: CallMediaType.video,
      );
      expect(backend.directSetSpeakerCalls, 0,
          reason: '路由必须只经 CallAudioRouteCoordinator，避免双 owner');
    });
  });
}

final class _RouteSink {
  final applied = <bool>[];
  bool fail = false;

  Future<void> apply(bool value) async {
    if (fail) throw StateError('platform route failed');
    applied.add(value);
  }
}

final class _Permissions implements CallPermissionGateway {
  @override
  Future<bool> request({required bool video}) async => true;
}

base class _ControllerBackend with CallBackendTestDefaults {
  final events = StreamController<CallBackendEvent>.broadcast();
  final routeCalls = <bool>[];
  int directSetSpeakerCalls = 0;

  Future<void> applyRoute(bool value) async {
    routeCalls.add(value);
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
  Future<void> accept() async {}
  @override
  Future<void> reject() async {}
  @override
  Future<void> hangup() async {}

  @override
  Future<void> setMuted(bool value) async {}
  @override
  Future<void> setSpeaker(bool value) async {
    directSetSpeakerCalls++;
    routeCalls.add(value);
  }

  @override
  Future<void> switchCamera() async {}
}
