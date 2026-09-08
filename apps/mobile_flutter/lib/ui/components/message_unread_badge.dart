import 'package:flutter/cupertino.dart';

String? messageUnreadBadgeLabel(int unreadCount) {
  if (unreadCount <= 0) return null;
  return unreadCount > 99 ? '99+' : '$unreadCount';
}

final class MessageUnreadBadge extends StatelessWidget {
  const MessageUnreadBadge({
    super.key,
    required this.unreadCount,
    required this.child,
  });

  final int unreadCount;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final label = messageUnreadBadgeLabel(unreadCount);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        if (label != null)
          Positioned(
            top: -7,
            right: -11,
            child: Semantics(
              label: '$label 条未读消息',
              child: Container(
                key: const Key('message-unread-badge'),
                constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: const BoxDecoration(
                  color: Color(0xfffa5151),
                  borderRadius: BorderRadius.all(Radius.circular(9)),
                ),
                alignment: Alignment.center,
                child: Text(
                  label,
                  style: const TextStyle(
                    color: CupertinoColors.white,
                    fontSize: 10,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
