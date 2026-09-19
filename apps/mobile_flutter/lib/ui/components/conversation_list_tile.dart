import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart'
    show ValueListenable;

import '../chat/wechat_unread_badge.dart';
import '../chat/conversation_mention_banner.dart';
import '../foundation/changliao_icons.dart';
import '../foundation/wechat_tokens.dart';
import '../../core/support_identity_repository.dart';
import 'wechat_official_name.dart';

final class ConversationListTile extends StatelessWidget {
  const ConversationListTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.timeLabel,
    required this.avatar,
    this.unreadCount = 0,
    this.hasPendingMention = false,
    this.muted = false,
    this.pinnedGroup = false,
    this.onTap,
    this.onLongPress,
    this.supportIdentities,
    this.userId,
    this.matrixUserId,
    this.draftListenable,
  });

  final String title;
  final String subtitle;
  final String timeLabel;
  final Widget avatar;
  final int unreadCount;
  final bool hasPendingMention;
  final bool muted;
  final bool pinnedGroup;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final SupportIdentityRepository? supportIdentities;
  final String? userId;
  final String? matrixUserId;

  /// BUG-20：未发送的草稿正文通知器；非空时副标题渲染为红色「草稿：」
  /// 前缀。逐 tile 监听，草稿更新只重建本 tile。
  final ValueListenable<String?>? draftListenable;

  Widget _summary(BuildContext context) =>
      ConversationSummaryWithMention(
        summary: subtitle,
        hasPendingMention: hasPendingMention,
        maxLines: 1,
        style: const TextStyle(
          color: WeChatColors.textSecondary,
          fontSize: WeChatTypography.subhead,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = CupertinoTheme.of(context);
    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: onTap,
      onLongPress: onLongPress,
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
                    WeChatOfficialName(
                      name: title,
                      supportIdentities: supportIdentities,
                      userId: userId,
                      matrixUserId: matrixUserId,
                      nameStyle: TextStyle(
                        color: theme.textTheme.textStyle.color,
                        fontSize: WeChatTypography.body,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: WeChatSpacing.xs),
                    if (draftListenable != null)
                      ValueListenableBuilder<String?>(
                        valueListenable: draftListenable!,
                        builder: (context, draft, _) => (draft == null ||
                                draft.isEmpty)
                            ? _summary(context)
                            : Text.rich(
                                TextSpan(
                                  text: '草稿：',
                                  style: const TextStyle(
                                    color: WeChatColors.danger,
                                    fontSize: WeChatTypography.subhead,
                                  ),
                                  children: [
                                    TextSpan(
                                      text: draft,
                                      style: const TextStyle(
                                        color: WeChatColors.textSecondary,
                                        fontSize: WeChatTypography.subhead,
                                      ),
                                    ),
                                  ],
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                      )
                    else
                      _summary(context),
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
