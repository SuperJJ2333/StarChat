import 'dart:async';

import 'package:flutter/services.dart';

import '../../core/notification/foreground_sound_service.dart';
import '../../core/notification/notification_coordinator.dart';
import '../../core/notification/sound_type.dart';

/// 响铃驱动抽象：可注入测试。
abstract interface class CallAlertDriver {
  Future<void> startRingtone(SoundType ringtone);
  Future<void> stopRingtone();
  Future<void> vibrate();
}

/// 系统提示音驱动（测试/降级用）。
final class SystemCallAlertDriver implements CallAlertDriver {
  const SystemCallAlertDriver();

  @override
  Future<void> startRingtone(SoundType ringtone) =>
      SystemSound.play(SystemSoundType.alert);

  @override
  Future<void> stopRingtone() async {}

  @override
  Future<void> vibrate() => HapticFeedback.heavyImpact();
}

/// SE 铃声驱动（PRD §9/§10）：语音/视频来电与主叫等待各自循环铃声，
/// 震动沿用系统 Haptic（PRD §37）；受"通话通知"设置开关约束。
final class SoundServiceCallAlertDriver implements CallAlertDriver {
  SoundServiceCallAlertDriver({
    ForegroundSoundService? sound,
    bool Function()? enabled,
  })  : _sound = sound,
        _enabled = enabled;

  final ForegroundSoundService? _sound;
  final bool Function()? _enabled;
  SoundType? _current;

  @override
  Future<void> startRingtone(SoundType ringtone) async {
    final enabled = _enabled;
    if (enabled != null && !enabled()) return;
    if (_current == ringtone) return; // 循环中重复触发幂等。
    _current = ringtone;
    final sound = _sound;
    if (sound == null) return;
    await sound.startLoop(ringtone);
  }

  @override
  Future<void> stopRingtone() async {
    _current = null;
    final sound = _sound;
    if (sound == null) return;
    await sound.stopLoop();
  }

  @override
  Future<void> vibrate() => HapticFeedback.heavyImpact();
}

/// 通话响铃/震动循环：来电与主叫等待期间循环提醒，
/// 接通、挂断、超时、拒接时立即停止。微信式"铃声+震动"提醒。
base class CallAlerts {
  CallAlerts({
    CallAlertDriver? driver,
    this.interval = const Duration(milliseconds: 1800),
  }) : driver = driver ?? const SystemCallAlertDriver();

  final CallAlertDriver driver;

  /// 响铃节拍：即时响一次，随后按该间隔循环（驱动内铃声本身连续循环，
  /// 该节拍维持震动节奏并确保铃声存活）。
  final Duration interval;

  Timer? _timer;
  SoundType? _ringtone;
  bool _ringing = false;

  bool get ringing => _ringing;

  void start(SoundType ringtone) {
    _ringtone = ringtone;
    if (_ringing) return;
    _ringing = true;
    unawaited(_fire());
    _timer = Timer.periodic(interval, (_) => unawaited(_fire()));
  }

  void stop() {
    if (!_ringing) return;
    _ringing = false;
    _timer?.cancel();
    _timer = null;
    _ringtone = null;
    unawaited(driver.stopRingtone().catchError((_) {}));
  }

  Future<void> _fire() async {
    final ringtone = _ringtone;
    if (ringtone == null) return;
    try {
      await driver.startRingtone(ringtone);
      await driver.vibrate();
    } catch (_) {
      // 提醒驱动异常（如测试环境无平台通道）不影响通话状态机。
    }
  }

  void dispose() {
    stop();
  }
}

/// 通话相位提示音（PRD §5）：接通确认音与结束音，经统一通知系统播放。
abstract interface class CallSoundCues {
  void connected();
  void ended();
}

/// 经 NotificationCoordinator 播放；未就绪（测试/异常）时静默。
final class NotificationSystemCallSoundCues implements CallSoundCues {
  const NotificationSystemCallSoundCues();

  @override
  void connected() => _play(SoundType.callConnected);

  @override
  void ended() => _play(SoundType.callEnded);

  void _play(SoundType type) {
    final coordinator = NotificationSystemHandle.coordinator;
    if (coordinator == null) return;
    unawaited(coordinator.playUiSound(type));
  }
}
