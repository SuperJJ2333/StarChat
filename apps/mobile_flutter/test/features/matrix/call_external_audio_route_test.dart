import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/call_audio_route_coordinator.dart';
import 'package:liuhetong_mobile/features/matrix/call_controller.dart';
import 'package:liuhetong_mobile/features/matrix/platform_audio_route_observer.dart';

/// 外设（蓝牙 / 有线耳机 / USB）在场时的音频路由语义。
///
/// 生产要求（本轮重点）：`externalDevicePresent` **不能只是测试里的假参数**，
/// 必须来自真实平台状态。Android 用 `AudioManager` 的通信设备枚举，
/// iOS 用只读的 `AVAudioSession` 路由快照——两者都只作为**输入**喂给
/// [CallAudioRouteCoordinator]，它仍然是唯一的 route authority。
void main() {
  group('parseExternalAudioDeviceNames（真实平台载荷解析）', () {
    test('蓝牙 / 有线耳机 / USB 都算外设', () {
      for (final name in [
        'bluetooth',
        'bluetooth-sco',
        'wired-headset',
        'usb',
        'usb-device',
        'usb-headset',
      ]) {
        expect(parseExternalAudioDeviceNames([name]), isTrue,
            reason: '$name 必须被识别为外设');
      }
    });

    test('内置听筒 / 扬声器不算外设', () {
      for (final name in ['earpiece', 'speaker', 'speakerphone']) {
        expect(parseExternalAudioDeviceNames([name]), isFalse,
            reason: '$name 是内置设备，不是外设');
      }
    });

    test('混合列表只要含外设即为真；空列表/未知名称为假', () {
      expect(
          parseExternalAudioDeviceNames(['earpiece', 'speaker', 'bluetooth']),
          isTrue);
      expect(parseExternalAudioDeviceNames(['earpiece', 'speaker']), isFalse);
      expect(parseExternalAudioDeviceNames([]), isFalse);
      expect(parseExternalAudioDeviceNames(['unknown-thing']), isFalse);
    });

    test('大小写与空白不敏感（平台命名不完全可控）', () {
      expect(parseExternalAudioDeviceNames([' Bluetooth ']), isTrue);
      expect(parseExternalAudioDeviceNames(['WIRED-HEADSET']), isTrue);
    });
  });

  group('平台路由事件解析（MethodChannel 载荷）', () {
    test('布尔载荷直接映射', () {
      expect(parseAudioRouteEvent({'externalDevicePresent': true}), isTrue);
      expect(parseAudioRouteEvent({'externalDevicePresent': false}), isFalse);
    });

    test('设备名列表载荷按同一规则解析', () {
      expect(
          parseAudioRouteEvent({
            'devices': ['earpiece', 'bluetooth'],
          }),
          isTrue);
      expect(
          parseAudioRouteEvent({
            'devices': ['earpiece', 'speaker']
          }),
          isFalse);
    });

    test('无法识别的载荷返回 null（不得猜成 false 而误抢外设）', () {
      expect(parseAudioRouteEvent(null), isNull);
      expect(parseAudioRouteEvent('nonsense'), isNull);
      expect(parseAudioRouteEvent(const <String, Object?>{}), isNull);
    });
  });

  group('外设在场时的自动策略', () {
    test('语音 + 外设 = 保持外设（不下发 speaker=true）', () async {
      final sink = _Sink();
      final route = CallAudioRouteCoordinator(apply: sink.apply);
      await route.setExternalRouteActive(true);
      await route.applyPreMediaRoute(CallMediaType.audio);
      await route.preferForConnected(CallMediaType.audio);
      expect(route.speaker, isFalse);
      expect(route.hasUserPreference, isFalse);
      for (final applied in sink.applied) {
        expect(applied, isFalse, reason: '自动策略绝不能抢走当前外设');
      }
    });

    test('视频 + 外设 = 不强制扬声器（外设优先），且必须显式交还路由', () async {
      final sink = _Sink();
      final route = CallAudioRouteCoordinator(apply: sink.apply);
      await route.applyPreMediaRoute(CallMediaType.video);
      // 视频默认会先清场（speaker=false）。
      expect(route.speaker, isFalse);

      // 通话中插入蓝牙：自动策略必须重新评估，且不能把声音抢到扬声器。
      await route.setExternalRouteActive(true);
      await route.preferForConnected(CallMediaType.video);
      expect(route.speaker, isFalse, reason: '外设在场时视频也不得强制扬声器');
      expect(sink.applied.last, isFalse,
          reason: '必须显式下发 speaker=false 让系统路由到外设');
    });

    test('无外设时视频默认仍是扬声器', () async {
      final sink = _Sink();
      final route = CallAudioRouteCoordinator(apply: sink.apply);
      await route.applyPreMediaRoute(CallMediaType.video);
      await route.preferForConnected(CallMediaType.video);
      expect(route.speaker, isTrue);
      expect(sink.applied.last, isTrue);
    });
  });

  group('外设动态变化', () {
    test('通话中插入有线耳机：自动策略重新评估到外设', () async {
      final sink = _Sink();
      final route = CallAudioRouteCoordinator(apply: sink.apply);
      await route.applyPreMediaRoute(CallMediaType.video);
      await route.preferForConnected(CallMediaType.video);
      expect(route.speaker, isTrue, reason: '视频默认扬声器');

      // 插入耳机 → 必须交还路由。
      await route.setExternalRouteActive(true);
      expect(route.speaker, isFalse, reason: '插入耳机后不得继续强制扬声器');
      expect(sink.applied.last, isFalse);
    });

    test('外设拔出：回到策略默认（视频=扬声器、语音=听筒）', () async {
      final sink = _Sink();
      final route = CallAudioRouteCoordinator(apply: sink.apply);
      await route.applyPreMediaRoute(CallMediaType.video);
      await route.setExternalRouteActive(true);
      await route.preferForConnected(CallMediaType.video);
      expect(route.speaker, isFalse);

      await route.setExternalRouteActive(false);
      expect(route.speaker, isTrue, reason: '外设拔出后回到视频默认扬声器');
      expect(sink.applied.last, isTrue);
    });

    test('反复插拔每次状态变化只下发一次（不抖动）', () async {
      final sink = _Sink();
      final route = CallAudioRouteCoordinator(apply: sink.apply);
      await route.applyPreMediaRoute(CallMediaType.audio);
      await route.preferForConnected(CallMediaType.audio);
      final before = sink.applied.length;

      // 语音场景下策略值始终是 speaker=false，但外设状态**变化**时必须显式
      // 重新下发一次（平台侧需要一次交还/取回），而重复的同值状态不触发。
      await route.setExternalRouteActive(true); // 插入
      await route.setExternalRouteActive(true); // 重复通知：不下发
      await route.setExternalRouteActive(false); // 拔出
      await route.setExternalRouteActive(false); // 重复通知：不下发

      expect(sink.applied.length, before + 2,
          reason: '每次真实的外设状态变化恰好下发一次；重复通知不得下发');
      expect(sink.applied.skip(before), [false, false]);
    });
  });

  group('用户显式选择优先于外设', () {
    test('用户手动点免提 → 覆盖蓝牙（系统电话语义）', () async {
      final sink = _Sink();
      final route = CallAudioRouteCoordinator(apply: sink.apply);
      await route.setExternalRouteActive(true);
      await route.applyPreMediaRoute(CallMediaType.audio);
      await route.preferForConnected(CallMediaType.audio);
      expect(route.speaker, isFalse);

      await route.toggleSpeaker(CallMediaType.audio);
      expect(route.speaker, isTrue, reason: '用户手动免提必须能覆盖外设');
      expect(route.hasUserPreference, isTrue);
      expect(sink.applied.last, isTrue);
    });

    test('用户选择在外设插拔后不被覆盖', () async {
      final sink = _Sink();
      final route = CallAudioRouteCoordinator(apply: sink.apply);
      await route.applyPreMediaRoute(CallMediaType.audio);
      await route.toggleSpeaker(CallMediaType.audio); // 显式免提
      expect(route.speaker, isTrue);

      await route.setExternalRouteActive(true);
      expect(route.speaker, isTrue, reason: '显式选择不得被外设变化覆盖');
      await route.setExternalRouteActive(false);
      expect(route.speaker, isTrue);
    });

    test('用户显式听筒在外设拔出后仍然是听筒', () async {
      final sink = _Sink();
      final route = CallAudioRouteCoordinator(apply: sink.apply);
      await route.applyPreMediaRoute(CallMediaType.video);
      await route.preferForConnected(CallMediaType.video);
      expect(route.speaker, isTrue);

      await route.setSpeaker(false,
          type: CallMediaType.video, markUserPreference: true);
      expect(route.speaker, isFalse);

      await route.setExternalRouteActive(true);
      await route.setExternalRouteActive(false);
      expect(route.speaker, isFalse, reason: '显式听筒不得被外设拔出改回扬声器');
    });
  });

  group('媒体流重建 / ICE restart', () {
    test('stream recreation 与 ICE restart 不改变用户偏好', () async {
      final sink = _Sink();
      final route = CallAudioRouteCoordinator(apply: sink.apply);
      await route.applyPreMediaRoute(CallMediaType.video);
      await route.preferForConnected(CallMediaType.video);
      await route.setSpeaker(false,
          type: CallMediaType.video, markUserPreference: true);

      route.onLocalStreamRecreated();
      await route.reapply();
      await route.preferForConnected(CallMediaType.video);
      expect(route.speaker, isFalse, reason: 'ICE restart / 重建不得重置偏好');
      expect(route.hasUserPreference, isTrue);
    });
  });

  group('生产 wiring：平台观察者真的接进 coordinator', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('chatflow/audio_route'), null);
    });

    test('Android 平台通道的设备枚举驱动 externalDevicePresent', () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('chatflow/audio_route'),
              (call) async {
        calls.add(call.method);
        if (call.method == 'currentAudioRoute') {
          return <String, Object?>{
            'devices': ['earpiece', 'bluetooth'],
          };
        }
        return null;
      });

      final sink = _Sink();
      final route = CallAudioRouteCoordinator(apply: sink.apply);
      final observer = PlatformAudioRouteObserver(route: route);
      addTearDown(observer.dispose);

      await observer.refresh();

      expect(calls, contains('currentAudioRoute'), reason: '生产观察者必须真的查询平台通信设备');
      expect(route.externalRouteActive, isTrue,
          reason: '平台报告外设 → coordinator 必须知道');
    });

    test('平台返回无外设时 coordinator 保持内置路由', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('chatflow/audio_route'),
              (call) async {
        if (call.method == 'currentAudioRoute') {
          return <String, Object?>{
            'devices': ['earpiece', 'speaker'],
          };
        }
        return null;
      });
      final sink = _Sink();
      final route = CallAudioRouteCoordinator(apply: sink.apply);
      final observer = PlatformAudioRouteObserver(route: route);
      addTearDown(observer.dispose);

      await observer.refresh();
      expect(route.externalRouteActive, isFalse);
    });

    test('平台通道不可用时保持上一次已知状态（不猜测、不抛错）', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('chatflow/audio_route'),
              (call) async => throw PlatformException(code: 'unavailable'));

      final sink = _Sink();
      final route = CallAudioRouteCoordinator(apply: sink.apply);
      await route.setExternalRouteActive(true);
      final observer = PlatformAudioRouteObserver(route: route);
      addTearDown(observer.dispose);

      await expectLater(observer.refresh(), completes);
      expect(route.externalRouteActive, isTrue,
          reason: '通道故障不得把已知的外设状态猜成「无外设」（会抢路由）');
    });
  });
}

final class _Sink {
  final applied = <bool>[];

  Future<void> apply(bool value) async => applied.add(value);
}
