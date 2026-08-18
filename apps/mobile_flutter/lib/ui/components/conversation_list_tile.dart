import 'package:flutter/cupertino.dart';

import '../chat/wechat_unread_badge.dart';
import '../foundation/changliao_icons.dart';
import '../foundation/wechat_tokens.dart';

final class ConversationListTile extends StatelessWidget {
  const ConversationListTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.timeLabel,
    required this.avatar,
    this.unreadCount = 0,
    this.muted = false,
    this.pinnedGroup = false,
    this.onTap,
  });

  final String title;
  final String subtitle;
  final String timeLabel;
  final Widget avatar;
  final int unreadCount;
  final bool muted;
  final bool pinnedGroup;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = CupertinoTheme.of(context);
    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: onTap,
      child: ColoredBox(
        key: const Key('conversation-elevated-surface'),
        color: pinnedGroup
            ? WeChatColors.navigationSurface(context)
            : WeChatColors.elevatedSurface(context),
        child: Container(
          constraints: const BoxConstraints(
            minHeight: WeChatDimensions.conversationTileHeight,
          ),
          padding: const EdgeInsets.symmetric(horizontal: WeChatSpacing.lg),
          child: Row(
            children: [
              ClipRRect(
                key: const Key('conversation-avatar-slot'),
                borderRadius: BorderRadius.circular(WeChatRadius.control),
                child: SizedBox.square(
                  dimension: WeChatDimensions.conversationAvatar,
                  child: avatar,
                ),
              ),
              const SizedBox(width: WeChatSpacing.md),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: theme.textTheme.textStyle.color,
                        fontSize: WeChatTypography.body,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: WeChatSpacing.xs),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: WeChatColors.textSecondary,
                        fontSize: WeChatTypography.subhead,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: WeChatSpacing.sm),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    timeLabel,
                    style: const TextStyle(
                      color: WeChatColors.textSecondary,
                      fontSize: WeChatTypography.caption,
                    ),
                  ),
                  const SizedBox(height: WeChatSpacing.sm),
                  if (unreadCount > 0)
                    WeChatUnreadBadge(count: unreadCount)
                  else if (muted)
                    Semantics(
                      container: true,
                      label: '已静音',
                      excludeSemantics: true,
                      child: const Icon(
                        ChangliaoIcons.muted,
                        size: 16,
                        color: WeChatColors.textSecondary,
                      ),
                    )
                  else
                    const SizedBox(height: 16),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
