import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import '../foundation/wechat_tokens.dart';
import 'moment_reaction_tokens.dart';

final class MomentLikeFeedback extends StatefulWidget {
  const MomentLikeFeedback({super.key, required this.liked});
  final bool liked;
  @override
  State<MomentLikeFeedback> createState() => _MomentLikeFeedbackState();
}

final class _MomentLikeFeedbackState extends State<MomentLikeFeedback>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
      vsync: this, duration: MomentReactionTokens.likeDuration);

  @override
  void didUpdateWidget(MomentLikeFeedback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.liked &&
        widget.liked &&
        !MediaQuery.disableAnimationsOf(context)) {
      _controller.forward(from: 0);
    } else if (!widget.liked || MediaQuery.disableAnimationsOf(context)) {
      _controller.reset();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) _controller.reset();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        final active = _controller.isAnimating;
        return SizedBox(
            width: 30,
            height: 30,
            child: Stack(alignment: Alignment.center, children: [
              if (active)
                for (var i = 0; i < 6; i++)
                  Transform.translate(
                      offset: Offset(math.cos(i * math.pi / 3),
                              math.sin(i * math.pi / 3)) *
                          (8 + 6 * t),
                      child: Opacity(
                          opacity: (1 - t) * .65,
                          child: const SizedBox(
                              width: 2,
                              height: 2,
                              child: DecoratedBox(
                                  decoration: BoxDecoration(
                                      color: WeChatColors.brandPrimary,
                                      shape: BoxShape.circle))))),
              Transform.scale(
                  key: const Key('moment-like-scale'),
                  scale: active
                      ? 1 + .18 * math.sin(t * math.pi * 2) * (1 - t)
                      : 1,
                  child: Icon(
                      widget.liked
                          ? CupertinoIcons.heart_fill
                          : CupertinoIcons.heart,
                      color: widget.liked ? WeChatColors.brandPrimary : null,
                      size: 20)),
            ]));
      });
}
