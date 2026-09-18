import 'package:flutter/cupertino.dart';

import 'motion_preferences.dart';

/// 应用内所有页面跳转使用的路由。
///
/// 为什么需要它（BUG-08）：`CupertinoPageRoute` 的转场时长是固定常量
/// （500ms），Flutter 只会在**系统**无障碍开关
/// （`AccessibilityFeatures.disableAnimations`）打开时把 `AnimationController`
/// 的时长压到 5%。应用内的「减少动态效果」开关无法改变它，因此这里提供
/// 语义完全相同、仅转场时长跟随设置的路由。
///
/// 取值顺序：先读 navigator 上下文里的 `MediaQuery.disableAnimations`
/// （应用根已把设置投影进 MediaQuery，测试也可直接注入），拿不到时回退到
/// 全局设置。
final class MotionPageRoute<T> extends CupertinoPageRoute<T> {
  MotionPageRoute({
    required super.builder,
    super.title,
    super.settings,
    super.requestFocus,
    super.maintainState,
    super.fullscreenDialog,
    super.allowSnapshotting,
    super.barrierDismissible,
  });

  /// 与框架处理系统级「减少动态效果」的方式一致：压到 5%（约 25ms），
  /// 而不是真正的 0 时长，避免零时长动画的边界问题。
  static const _reducedScale = 0.05;

  bool get _reduceMotion {
    final context = navigator?.context;
    if (context != null) {
      final value = MediaQuery.maybeDisableAnimationsOf(context);
      if (value != null) return value;
    }
    return motionReduceMotionResolver();
  }

  @override
  Duration get transitionDuration => _reduceMotion
      ? super.transitionDuration * _reducedScale
      : super.transitionDuration;

  @override
  Duration get reverseTransitionDuration => _reduceMotion
      ? super.reverseTransitionDuration * _reducedScale
      : super.reverseTransitionDuration;
}
