import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

enum MessageDirection { incoming, outgoing }

/// 气泡右侧的发送状态标识。
///
/// 用户可见文案统一词表（UI_DESIGN.md §7 消息，与 `OutboxStatus.label` 逐字一致）：
/// [waitingNetwork] →「等待网络」（灰色小时钟 + 点击立即重试）；[failed] →
/// 红色感叹号（**仅**服务端明确拒绝）；[sending] / [sent] 不显示多余标记；
///「等待发送」保留给 outbox `queued`（本地排队待发）行，不得与 [waitingNetwork]
/// 混用。
///
/// [waitingNetwork] 表示「因网络原因暂未发出，等网络恢复后自动重发」——
/// 弱网/无网绝不显示成红色感叹号（那会让用户以为消息已经彻底失败）。
enum MessageDeliveryState { sending, sent, waitingNetwork, failed }

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
    this.bubbleKey,
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
  final Key? bubbleKey;

  /// Green outgoing bubbles retain dark ink, including in night mode.
  static Color foregroundOf(BuildContext context) {
    final bubble = context.findAncestorWidgetOfExactType<WeChatMessageBubble>();
    return bubble?.direction == MessageDirection.outgoing ||
            CupertinoTheme.brightnessOf(context) != Brightness.dark
        ? CupertinoColors.black
        : WeChatColors.darkTextPrimary;
  }

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
              key: const Key('message-delivery-failed'),
              padding: const EdgeInsets.all(4),
              onPressed: onRetry,
              child: const Icon(
                CupertinoIcons.exclamationmark_circle_fill,
                color: WeChatColors.danger,
              ),
            )
          else if (state == MessageDeliveryState.waitingNetwork)
            // 等待网络：小时钟 + 文案，绝不出现红色感叹号；点击立即重试。
            //
            // 状态词表统一（UI_DESIGN.md §7 消息）：queued →「等待发送」、
            // waitingNetwork →「等待网络」。网络原因未发出的消息必须显示
            // 「等待网络」，不得再混用「等待发送」。
            CupertinoButton(
              key: const Key('message-delivery-waiting'),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              minimumSize: Size.zero,
              onPressed: onRetry,
              child: Semantics(
                button: true,
                label: '立即重试',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      CupertinoIcons.clock,
                      size: 14,
                      color: WeChatColors.textSecondary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      state == MessageDeliveryState.waitingNetwork
                          ? '等待网络'
                          : '等待发送',
                      style: const TextStyle(
                        fontSize: 11,
                        color: WeChatColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Flexible(
            child: KeyedSubtree(key: bubbleKey, child: decorateContent
                ? DecoratedBox(
                    decoration: BoxDecoration(
                      color: outgoing
                          ? WeChatColors.bubbleOutgoing
                          : CupertinoTheme.brightnessOf(context) ==
                                  Brightness.dark
                              ? WeChatColors.darkElevated
                              : CupertinoTheme.of(context).barBackgroundColor,
                      borderRadius: BorderRadius.circular(WeChatRadius.bubble),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      child: DefaultTextStyle.merge(
                        style: TextStyle(
                          color: outgoing
                              ? CupertinoColors.black
                              : foregroundOf(context),
                        ),
                        child: content,
                      ),
                    ),
                  )
                : content),
          ),
        ],
      ),
    );

    // WeChat shows the sender nickname right above the bubble, aligned with
    // the bubble edge (avatar width + gutter when an avatar is present).
    final showSenderName =
        !outgoing && senderName != null && senderName!.trim().isNotEmpty;
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
