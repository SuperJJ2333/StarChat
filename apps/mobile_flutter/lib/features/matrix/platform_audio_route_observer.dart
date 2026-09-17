import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'call_audio_route_coordinator.dart';

/// 外部音频设备名称 → 「是否存在外设」的判定（纯函数，可单测）。
///
/// 命名来自真实平台载荷：
/// - Android `flutter_webrtc` 的 `enumerateDevices('audiooutput')` 返回
///   `AudioDeviceKind.typeName`：`bluetooth` / `wired-headset` /
///   `speaker` / `earpiece`（见插件 `AudioDeviceKind`）；
/// - iOS 只读 `AVAudioSession` 路由快照返回 `bluetooth-sco` /
///   `bluetooth-a2dp` / `headset` / `usb` 等。
///
/// 只有**外设**才算外设：内置听筒与扬声器不算。
@visibleForTesting
bool parseExternalAudioDeviceNames(Iterable<String> names) {
  for (final raw in names) {
    final name = raw.trim().toLowerCase();
    if (name.isEmpty) continue;
    if (name.startsWith('bluetooth')) return true;
    if (name.startsWith('wired')) return true;
    if (name.startsWith('headset')) return true;
    if (name.startsWith('usb')) return true;
    if (name.startsWith('airplay')) return true;
    if (name.startsWith('car')) return true;
    if (name.startsWith('hdmi')) return true;
  }
  return false;
}

/// 平台路由事件载荷 → `externalDevicePresent`（纯函数，可单测）。
///
/// 返回 `null` 表示**载荷不可识别**——调用方必须保持上一次已知状态，
/// 绝不能猜成 `false`（那会授权自动策略把声音抢回扬声器）。
@visibleForTesting
bool? parseAudioRouteEvent(Object? payload) {
  if (payload is bool) return payload;
  if (payload is Map) {
    final present = payload['externalDevicePresent'];
    if (present is bool) return present;
    final devices = payload['devices'];
    if (devices is List) {
      return parseExternalAudioDeviceNames(devices.whereType<String>());
    }
  }
  return null;
}

/// 只读的**平台路由观察者**（Task：外设真实接线）。
///
/// 职责边界（非常重要）：本类**不是**第二个 route owner。它只把平台真实的
/// 「是否存在外部音频设备」喂给 [CallAudioRouteCoordinator]，由后者独占
/// speaker/earpiece 策略。平台侧的通信设备切换（`setCommunicationDevice` /
/// `AVAudioSession` 路由）仍由 `flutter_webrtc` 与系统负责，这里绝不另建
/// 一套 AudioManager 状态机与它对抗。
///
/// 为什么需要轮询：通话中插入/拔出耳机、蓝牙 SCO 连接都可能在**通话已建立
/// 之后**发生，而 Flutter 侧没有可靠的路由变化回调（`ondevicechange` 仅覆盖
/// 采集设备，且已被 Matrix VoIP 占用）。因此以低频（默认 2s，且只在外设状态
/// 需要重新评估的通话期间运行）查询平台快照。
final class PlatformAudioRouteObserver {
  PlatformAudioRouteObserver({
    required this.route,
    this.channel = const MethodChannel('chatflow/audio_route'),
    this.interval = const Duration(seconds: 2),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final CallAudioRouteCoordinator route;
  final MethodChannel channel;
  final Duration interval;
  final DateTime Function() _now;

  Timer? _timer;
  bool _disposed = false;
  bool _inFlight = false;

  /// 上一次成功读取到的时间（诊断用；不含设备名/地址）。
  DateTime? lastRefreshAt;
  int refreshCount = 0;
  int failureCount = 0;

  /// 开始按 [interval] 观察（幂等）。
  void start() {
    if (_disposed || _timer != null) return;
    unawaited(refresh());
    _timer = Timer.periodic(interval, (_) => unawaited(refresh()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// 拉取一次平台状态并更新 coordinator。**绝不抛错**，绝不猜测状态。
  Future<void> refresh() async {
    if (_disposed || _inFlight) return;
    _inFlight = true;
    try {
      final payload = await channel.invokeMethod<Object?>('currentAudioRoute');
      final external = parseAudioRouteEvent(payload);
      if (_disposed) return;
      if (external == null) {
        // 平台不支持/载荷不可识别：保持上一次已知状态（fail-safe，
        // 不是 fail-open 到「无外设」）。
        failureCount++;
        return;
      }
      refreshCount++;
      lastRefreshAt = _now();
      await route.setExternalRouteActive(external);
    } catch (_) {
      failureCount++;
    } finally {
      _inFlight = false;
    }
  }

  void dispose() {
    _disposed = true;
    stop();
  }
}
