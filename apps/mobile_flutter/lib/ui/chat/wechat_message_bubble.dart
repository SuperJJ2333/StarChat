import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

enum MessageDirection { incoming, outgoing }

enum MessageDeliveryState { sending, sent, failed }

final class WeChatMessageBubble extends StatelessWidget {
  const WeChatMessageBubble({
    super.key,
    required this.direction,
    required this.content,
    this.avatar,
    this.state = MessageDeliveryState.sent,
    this.onAvatarTap,
    this.onRetry,
  });

  final MessageDirection direction;
  final Widget content;
  final Widget? avatar;
  final MessageDeliveryState state;
  final VoidCallback? onAvatarTap;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final outgoing = direction == MessageDirection.outgoing;
    final avatarContent = avatar;
    final avatarSlot = avatarContent == null
        ? null
        : SizedBox.square(
            key: const Key('message-avatar-slot'),
            dimension: WeChatDimensions.messageAvatar,
            child: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: onAvatarTap,
              child: avatarContent,
            ),
          );
    final message = Flexible(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment:
            outgoing ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (state == MessageDeliveryState.failed)
            CupertinoButton(
              padding: const EdgeInsets.all(4),
              onPressed: onRetry,
              child: const Icon(
                CupertinoIcons.exclamationmark_circle_fill,
                color: WeChatColors.danger,
              ),
            ),
          Flexible(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: outgoing
                    ? WeChatColors.bubbleOutgoing
                    : CupertinoTheme.of(context).barBackgroundColor,
                borderRadius: BorderRadius.circular(WeChatRadius.bubble),
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                child: content,
              ),
            ),
          ),
          if (state == MessageDeliveryState.sending)
            const Padding(
              padding: EdgeInsets.all(4),
              child: CupertinoActivityIndicator(radius: 7),
            ),
        ],
      ),
    );

    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: .86,
        child: Row(
          mainAxisAlignment:
              outgoing ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!outgoing && avatarSlot != null) avatarSlot,
            if (!outgoing && avatarSlot != null) const SizedBox(width: 8),
            message,
            if (outgoing && avatarSlot != null) const SizedBox(width: 8),
            if (outgoing && avatarSlot != null) avatarSlot,
          ],
        ),
      ),
    );
  }
}
