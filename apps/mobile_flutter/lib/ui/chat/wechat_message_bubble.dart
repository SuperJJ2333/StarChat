import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

enum MessageDirection { incoming, outgoing }

/// 气泡右侧的发送状态标识。
///
/// 用户可见文案统一词表（UI_DESIGN.md §7 消息，2026-09-19 用户修订）：
/// [waitingNetwork] 与 [failed] 视觉一致——红色感叹号（**未发出必须及时
/// 警告**），点击立即重发；区别在行为：[waitingNetwork] 是网络原因暂未
/// 发出，网络恢复后自动重发（感叹号在重发期间保持，成功后消失），
/// [failed] 是服务端明确拒绝，仅点击重发；[sending] / [sent] 不显示多余
/// 标记（发送中不增加加载感知）；「等待发送」保留给 outbox `queued`
/// （本地排队待发）行，不得与本状态混用。
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
            // 网络原因暂未发出（2026-09-19 用户修订）：与终局失败一样显示
            // 红色感叹号 + 点击立即重发；区别在行为——网络恢复后自动重发。
            CupertinoButton(
              key: const Key('message-delivery-waiting'),
              padding: const EdgeInsets.all(4),
              onPressed: onRetry,
              child: Semantics(
                button: true,
                label: '立即重发',
                child: const Icon(
                  CupertinoIcons.exclamationmark_circle_fill,
                  color: WeChatColors.danger,
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
