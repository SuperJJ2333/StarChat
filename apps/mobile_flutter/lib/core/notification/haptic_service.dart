import 'dart:async';

import 'package:flutter/services.dart';

import 'notification_decision.dart';

/// 震动驱动抽象：可注入测试。
abstract interface class HapticDriver {
  Future<void> trigger(HapticFeedbackKind kind);
}

/// 生产驱动：iOS/Android 系统 Haptic API（PRD §37：优先系统 API，
/// 不自模拟长马达波形）。
final class FlutterHapticDriver implements HapticDriver {
  const FlutterHapticDriver();

  @override
  Future<void> trigger(HapticFeedbackKind kind) async {
    switch (kind) {
      case HapticFeedbackKind.none:
        return;
      case HapticFeedbackKind.light:
        await HapticFeedback.lightImpact();
      case HapticFeedbackKind.doubleLight:
        // 双轻震：轻震 - 停顿 - 轻震（@我 / 特别关注）。
        await HapticFeedback.lightImpact();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await HapticFeedback.lightImpact();
      case HapticFeedbackKind.medium:
        await HapticFeedback.mediumImpact();
    }
  }
}

/// 震动反馈服务（PRD §37/§38）。声音与震动独立开关，由策略引擎
/// 按 prefs 分别裁决，本服务只负责执行。
final class HapticService {
  HapticService({HapticDriver? driver})
      : driver = driver ?? const FlutterHapticDriver();

  final HapticDriver driver;

  Future<void> trigger(HapticFeedbackKind kind) async {
    if (kind == HapticFeedbackKind.none) return;
    try {
      await driver.trigger(kind);
    } catch (_) {
      // 平台通道异常（如测试环境）不影响通知链路。
    }
  }
}
