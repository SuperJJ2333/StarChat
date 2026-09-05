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
    this.senderName,
    this.decorateContent = true,
    this.state = MessageDeliveryState.sent,
    this.onAvatarTap,
    this.onAvatarDoubleTap,
    this.onAvatarLongPress,
    this.onLongPress,
    this.onRetry,
    this.senderBadge,
  });

  final MessageDirection direction;
  final Widget content;
  final Widget? avatar;
  final String? senderName;
  final bool decorateContent;
  final MessageDeliveryState state;
  final VoidCallback? onAvatarTap;
  final VoidCallback? onAvatarDoubleTap;
  final VoidCallback? onAvatarLongPress;
  final VoidCallback? onLongPress;
  final VoidCallback? onRetry;

  /// 发送者头衔徽标（群主/管理员，QQ 式），显示在昵称前。
  final Widget? senderBadge;

  @override
  Widget build(BuildContext context) {
    final outgoing = direction == MessageDirection.outgoing;
    final avatarContent = avatar;
    final avatarSlot = avatarContent == null
        ? null
        : SizedBox.square(
            key: const Key('message-avatar-slot'),
            dimension: WeChatDimensions.messageAvatar,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onAvatarTap,
              onDoubleTap: onAvatarDoubleTap,
              onLongPress: onAvatarLongPress,
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
            child: decorateContent
                ? DecoratedBox(
                    decoration: BoxDecoration(
                      color: outgoing
                          ? WeChatColors.bubbleOutgoing
                          : CupertinoTheme.of(context).barBackgroundColor,
                      borderRadius: BorderRadius.circular(WeChatRadius.bubble),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      child: content,
                    ),
                  )
                : content,
          ),
        ],
      ),
    );

    // WeChat shows the sender nickname right above the bubble, aligned with
    // the bubble edge (avatar width + gutter when an avatar is present).
    final showSenderName = !outgoing &&
        senderName != null &&
        senderName!.trim().isNotEmpty;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPress: onLongPress,
      child: Align(
        alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: .86,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showSenderName)
                Padding(
                  key: const Key('message-sender-name'),
                  padding: const EdgeInsets.only(left: 48, bottom: 3),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (senderBadge != null) ...[
                      senderBadge!,
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: Text(
                        senderName!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: WeChatColors.messageSenderName,
                        ),
                      ),
                    ),
                  ]),
                ),
              Row(
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
            ],
          ),
        ),
      ),
    );
  }
}


