import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import '../foundation/changliao_icons.dart';
import 'message_unread_badge.dart';

/// The tab owns feedback so clearing works even when the Messages page is hidden.
final class MessagesTabIcon extends StatefulWidget {
  const MessagesTabIcon(
      {super.key,
      required this.unreadCount,
      required this.active,
      required this.onClearUnread});
  final int unreadCount;
  final bool active;
  final Future<void> Function() onClearUnread;
  @override
  State<MessagesTabIcon> createState() => _MessagesTabIconState();
}

final class _MessagesTabIconState extends State<MessagesTabIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _feedback = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 300));
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(
        tween: Tween<double>(begin: 1, end: .8)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 1),
    TweenSequenceItem(
        tween: Tween<double>(begin: .8, end: 1)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 1),
  ]).animate(_feedback);
  bool _clearing = false;
  Future<void> _clear() async {
    if (_clearing) return;
    _clearing = true;
    unawaited(HapticFeedback.mediumImpact());
    if (!MediaQuery.disableAnimationsOf(context)) _feedback.forward(from: 0);
    try {
      await widget.onClearUnread();
    } catch (_) {
      // A later gesture can retry; never expose exception text or strand feedback.
    } finally {
      _clearing = false;
    }
  }

  @override
  void dispose() {
    _feedback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: _clear,
        child: ScaleTransition(
          scale: _scale,
          child: MessageUnreadBadge(
              unreadCount: widget.unreadCount,
              child: Icon(widget.active
                  ? ChangliaoIcons.messagesFilled
                  : ChangliaoIcons.messages)),
        ),
      );
}
