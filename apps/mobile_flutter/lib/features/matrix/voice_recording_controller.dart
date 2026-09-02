import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart';

enum VoiceRecordingState {
  idle,
  recording,
  cancelArmed,
  textArmed,
  sendArmed,
  preview,
  uploading,
  failed
}

/// 手指滑入的底部目标区：
/// 左下圆形“取消”、右下圆形“转文字”、中部“松手发送”。
enum VoiceArmedTarget { none, cancel, text, send }

final class VoiceRecordingController extends ChangeNotifier {
  VoiceRecordingController({DateTime Function()? nowFactory})
      : _now = nowFactory ?? DateTime.now;

  /// 覆盖层底部目标区的几何常量，控制器命中判定与覆盖层绘制共用，
  /// 保证“画在哪里就能在哪里触发”。
  static const double targetEdgeInset = 12;
  static const double targetRowHeight = 96;
  static const double targetRowBottomInset = 150;

  /// 圆形目标的命中直径：圆区外侧再放宽半个间距，方便滑入。
  static double get targetHitExtent =>
      targetEdgeInset + VoiceRecordingController.targetRowHeight;

  /// 垂直命中带（距屏幕底部）：覆盖安全区差异，
  /// 略宽于目标区绘制范围，让手指不必精确压在圆心上。
  static const double _bandBottom = 110;
  static const double _bandTop = 330;

  final DateTime Function() _now;
  DateTime? _startedAt;

  VoiceRecordingState state = VoiceRecordingState.idle;
  Duration? duration;

  void start() {
    state = VoiceRecordingState.recording;
    _startedAt = _now();
    notifyListeners();
  }

  /// 拖动反馈（对齐参考图底部“取消 / 松手发送 / 转文字”三区布局）：
  /// - 手指滑入屏幕底部目标带：左圆→取消、右圆→转文字、中部→松手发送；
  /// - 目标带之外上滑（delta.dy ≤ -60）→ 武装取消（快捷手势保留）；
  /// - 带内优先于上滑判定，否则滑向右圆途中必经上滑位移，
  ///   会被误判成取消（转文字永远无法命中的根因之一）。
  /// [delta] 为相对按住起点的位移；[global] 为手指全局坐标；
  /// [page] 为屏幕逻辑尺寸。
  void updateDrag({
    required Offset delta,
    required Offset global,
    required Size page,
  }) {
    if (state != VoiceRecordingState.recording &&
        state != VoiceRecordingState.cancelArmed &&
        state != VoiceRecordingState.textArmed &&
        state != VoiceRecordingState.sendArmed) {
      return;
    }
    final fromBottom = page.height - global.dy;
    final inTargetBand = fromBottom >= _bandBottom && fromBottom <= _bandTop;
    final hitExtent = VoiceRecordingController.targetHitExtent;
    const upCancelThreshold = -60.0;
    final target = switch (global) {
      _ when inTargetBand && global.dx <= hitExtent => VoiceArmedTarget.cancel,
      _ when inTargetBand && global.dx >= page.width - hitExtent =>
        VoiceArmedTarget.text,
      _ when inTargetBand => VoiceArmedTarget.send,
      _ when delta.dy <= upCancelThreshold => VoiceArmedTarget.cancel,
      _ => VoiceArmedTarget.none,
    };
    final nextState = switch (target) {
      VoiceArmedTarget.cancel => VoiceRecordingState.cancelArmed,
      VoiceArmedTarget.text => VoiceRecordingState.textArmed,
      VoiceArmedTarget.send => VoiceRecordingState.sendArmed,
      VoiceArmedTarget.none => VoiceRecordingState.recording,
    };
    if (nextState != state) {
      state = nextState;
      notifyListeners();
    }
  }

  /// [explicit] 允许直接给定录音时长；缺省时按内部开始时间计算
  /// （时钟可注入，便于测试）。时长不足 1 秒视为无效，超过 60 秒钳制。
  void release([Duration? explicit]) {
    final value = explicit ??
        () {
          final started = _startedAt;
          return started == null ? Duration.zero : _now().difference(started);
        }();
    if (state == VoiceRecordingState.cancelArmed ||
        state == VoiceRecordingState.textArmed ||
        value < const Duration(seconds: 1)) {
      discard();
      return;
    }
    duration = value > const Duration(seconds: 60)
        ? const Duration(seconds: 60)
        : value;
    state = VoiceRecordingState.preview;
    notifyListeners();
  }

  void confirmSend() {
    if (state == VoiceRecordingState.preview) {
      state = VoiceRecordingState.uploading;
      notifyListeners();
    }
  }

  void fail() {
    state = VoiceRecordingState.failed;
    notifyListeners();
  }

  void discard() {
    duration = null;
    state = VoiceRecordingState.idle;
    notifyListeners();
  }
}
