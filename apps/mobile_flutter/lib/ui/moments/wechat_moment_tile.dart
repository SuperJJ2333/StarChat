import 'package:flutter/cupertino.dart';

import '../../features/moments/moment_models.dart';
import '../../features/matrix/profile_repository.dart';
import '../../features/contacts/user_identity.dart';
import '../components/user_avatar.dart';
import '../foundation/wechat_tokens.dart';
import 'wechat_moment_image_grid.dart';
import 'moment_action_menu.dart';
import 'wechat_moment_reactions.dart';
import 'moment_reaction_tokens.dart';
import 'moment_like_feedback.dart';

final class WeChatMomentTile extends StatelessWidget {
  const WeChatMomentTile({
    super.key,
    required this.item,
    this.onAuthorTap,
    this.onLike,
    this.onComment,
    this.onAdTap,
    this.likedOverride,
    this.onDelete,
    this.onOpen,
    this.onCommentTap,
    this.cacheNamespace = '',
    this.identityCache,
    this.detailMode = false,
    this.selectedCommentId,
    this.onPersonTap,
  });
  final MomentItem item;
  final bool detailMode;
  final String? selectedCommentId;
  final ValueChanged<MomentAuthor>? onPersonTap;
  final ProfileRepository? identityCache;
  final VoidCallback? onAuthorTap;
  final VoidCallback? onLike;
  final VoidCallback? onComment;
  final VoidCallback? onAdTap;
  final VoidCallback? onOpen;
  final ValueChanged<MomentCommentView>? onCommentTap;
  final String cacheNamespace;

  /// 删除入口：仅当当前用户是作者时由页面传入（非 null 才渲染按钮）。
  final VoidCallback? onDelete;
  final bool? likedOverride;

  @override
  Widget build(BuildContext context) => identityCache == null
      ? _buildContent(context)
      : ListenableBuilder(
          listenable: identityCache!,
          builder: (context, _) => _buildContent(context));

  UserIdentity _identity(MomentAuthor author) =>
      identityCache?.resolveIdentity(
          userId: author.userId,
          username: author.username,
          nickname: author.nickname,
          displayName: author.displayName,
          avatarUrl: author.avatarUrl) ??
      UserIdentity(
          displayName: identityDisplayName(
              nickname: author.nickname,
              displayName: author.displayName,
              username: author.username,
              userId: author.userId),
          publicDisplayName: author.displayName,
          avatarUrl: author.avatarUrl,
          avatarIsKnown: author.avatarUrl != null,
          cacheKey: author.userId);

  Widget _buildContent(BuildContext context) {
    final isAd = item.kind == 'AD';
    final isLiked = likedOverride ?? item.liked;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: isAd ? onAdTap : onOpen,
      onLongPressStart: isAd
          ? null
          : (details) => showMomentActionMenu(context,
              position: details.globalPosition,
              text: item.text,
              onDelete: onDelete),
      child: Container(
        decoration: BoxDecoration(
          color: WeChatColors.elevatedSurface(context),
          border: Border(
              bottom: BorderSide(
                  color: WeChatColors.resolve(context, WeChatColors.divider))),
          boxShadow: const [
            BoxShadow(
                color: MomentReactionTokens.shadow,
                offset: Offset(0, 1),
                blurRadius: 2)
          ],
        ),
        padding: const EdgeInsets.all(12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          GestureDetector(
            onTap: isAd
                ? null
                : onAuthorTap ??
                    (onPersonTap == null
                        ? null
                        : () => onPersonTap!(item.author)),
            child: UserAvatar(
              nickname: _identity(item.author).displayName,
              fallbackSeed: _identity(item.author).cacheKey,
              avatarUrl: _identity(item.author).avatarUrl,
              diagnosticSource: 'moments-feed',
              size: 42,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              GestureDetector(
                onTap: isAd
                    ? null
                    : onAuthorTap ??
                        (onPersonTap == null
                            ? null
                            : () => onPersonTap!(item.author)),
                child: Text(_identity(item.author).displayName,
                    key: const Key('moment-author-name'),
                    style: TextStyle(
                        color: WeChatColors.resolve(
                            context, WeChatColors.socialLink),
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
              ),
              const SizedBox(height: 4),
              Text(item.text),
              if (item.images.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: WeChatMomentImageGrid(
                      imageUrls: item.images,
                      imageCacheKeys: item.imageCacheKeys,
                      cacheNamespace: cacheNamespace),
                ),
              Row(children: [
                Flexible(
                    child: Text(formatMomentTime(item.createdAt),
                        style: const TextStyle(
                            color: WeChatColors.textSecondary, fontSize: 13))),
                const Spacer(),
                if (isAd)
                  CupertinoButton(
                    key: const Key('moment-ad-label'),
                    padding: EdgeInsets.zero,
                    onPressed: onAdTap,
                    child: const Text('广告',
                        style: TextStyle(
                            fontSize: 11, color: WeChatColors.textSecondary)),
                  )
                else ...[
                  CupertinoButton(
                    key: const Key('moment-like-button'),
                    padding: EdgeInsets.zero,
                    onPressed: onLike,
                    child: MomentLikeFeedback(liked: isLiked),
                  ),
                  Text(
                    '${item.likeCount}',
                    key: const Key('moment-like-count'),
                    style: const TextStyle(
                        color: WeChatColors.textSecondary, fontSize: 13),
                  ),
                  CupertinoButton(
                    key: const Key('moment-comment-button'),
                    padding: EdgeInsets.zero,
                    onPressed: onComment,
                    child: const Icon(CupertinoIcons.chat_bubble, size: 20),
                  ),
                  // 删除入口（仅作者可见——页面按作者身份传入 onDelete）。
                  if (onDelete != null)
                    CupertinoButton(
                      key: const Key('moment-delete-button'),
                      padding: EdgeInsets.zero,
                      onPressed: onDelete,
                      child: const Icon(CupertinoIcons.delete, size: 20),
                    ),
                ],
              ]),
              if (!isAd)
                WeChatMomentReactions(
                  item: item,
                  resolveIdentity: _identity,
                  onPersonTap: onPersonTap,
                  onCommentTap: onCommentTap,
                  selectedCommentId: selectedCommentId,
                  detailMode: detailMode,
                  cacheNamespace: cacheNamespace,
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}
