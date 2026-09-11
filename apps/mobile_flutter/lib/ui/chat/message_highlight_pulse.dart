import 'package:flutter/cupertino.dart';

/// 引用跳转/@提醒/搜索定位的消息高亮脉冲（规格 #3）：
/// 淡入 → 微信式闪一下 → 保持 → 淡出，结束时不残留任何背景。
/// `active` 由宿主在定位完成后置 true、超时后置 false；
/// 不确定宿主超时也不残留——序列自身在 1500ms 时归零。
final class MessageHighlightPulse extends StatefulWidget {
  const MessageHighlightPulse({
    super.key,
    required this.active,
    required this.child,
  });

  final bool active;
  final Widget child;

  @override
  State<MessageHighlightPulse> createState() => _MessageHighlightPulseState();
}

final class _MessageHighlightPulseState extends State<MessageHighlightPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1500));

  late final Animation<double> _opacity = TweenSequence<double>([
    TweenSequenceItem(
        tween: Tween(begin: 0.0, end: 1.0)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 8),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 7),
    TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 0.25)
            .chain(CurveTween(curve: Curves.easeInOut)),
        weight: 8),
    TweenSequenceItem(
        tween: Tween(begin: 0.25, end: 1.0)
            .chain(CurveTween(curve: Curves.easeInOut)),
        weight: 8),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 54),
    TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 0.0)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 15),
  ]).animate(_controller);

  @override
  void initState() {
    super.initState();
    if (widget.active) _controller.forward(from: 0);
  }

  @override
  void didUpdateWidget(MessageHighlightPulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _controller.forward(from: 0);
    } else if (!widget.active && oldWidget.active) {
      _controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: _opacity, child: widget.child);
}
