import 'dart:async';

import 'package:flutter/services.dart';

/// 响铃驱动抽象：可注入测试。
abstract interface class CallAlertDriver {
  Future<void> playAlertSound();
  Future<void> vibrate();
}

/// 生产驱动：系统提示音 + 强触感震动。
final class SystemCallAlertDriver implements CallAlertDriver {
  const SystemCallAlertDriver();

  @override
  Future<void> playAlertSound() => SystemSound.play(SystemSoundType.alert);

  @override
  Future<void> vibrate() => HapticFeedback.heavyImpact();
}

/// 通话响铃/震动循环：来电与主叫等待期间循环播放提醒，
/// 接通、挂断、超时、拒接时立即停止。微信式“铃声+震动”提醒。
base class CallAlerts {
  CallAlerts({
    CallAlertDriver? driver,
    this.interval = const Duration(milliseconds: 1800),
  }) : driver = driver ?? const SystemCallAlertDriver();

  final CallAlertDriver driver;

  /// 响铃节拍：即时响一次，随后按该间隔循环。
  final Duration interval;

  Timer? _timer;
  bool _ringing = false;

  bool get ringing => _ringing;

  void start() {
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
  }

  Future<void> _fire() async {
    try {
      await driver.playAlertSound();
      await driver.vibrate();
    } catch (_) {
      // 提醒驱动异常（如测试环境无平台通道）不影响通话状态机。
    }
  }

  void dispose() {
    stop();
  }
}
