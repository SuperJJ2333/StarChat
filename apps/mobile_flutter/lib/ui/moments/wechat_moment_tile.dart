import 'package:flutter/cupertino.dart';

import '../../features/moments/moment_models.dart';
import '../components/user_avatar.dart';
import '../foundation/wechat_tokens.dart';
import 'wechat_moment_image_grid.dart';

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
  });
  final MomentItem item;
  final VoidCallback? onAuthorTap;
  final VoidCallback? onLike;
  final VoidCallback? onComment;
  final VoidCallback? onAdTap;

  /// 删除入口：仅当当前用户是作者时由页面传入（非 null 才渲染按钮）。
  final VoidCallback? onDelete;
  final bool? likedOverride;

  @override
  Widget build(BuildContext context) {
    final isAd = item.kind == 'AD';
    final isLiked = likedOverride ?? item.liked;
    return Container(
      color: CupertinoColors.systemBackground,
      padding: const EdgeInsets.all(12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        GestureDetector(
          onTap: isAd ? null : onAuthorTap,
          child: UserAvatar(
            nickname: item.author.displayName,
            fallbackSeed: item.author.userId,
            avatarUrl: item.author.avatarUrl,
            diagnosticSource: 'moments-feed',
            size: 42,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            GestureDetector(
              onTap: isAd ? null : onAuthorTap,
              child: Text(item.author.displayName,
                  key: const Key('moment-author-name'),
                  style: const TextStyle(
                      color: WeChatColors.socialLink,
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 4),
            Text(item.text),
            if (item.images.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: WeChatMomentImageGrid(imageUrls: item.images),
              ),
            Row(children: [
              Text(formatMomentTime(item.createdAt),
                  style: const TextStyle(
                      color: WeChatColors.textSecondary, fontSize: 13)),
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
                  child: Icon(
                      isLiked
                          ? CupertinoIcons.heart_fill
                          : CupertinoIcons.heart,
                      color: isLiked ? WeChatColors.brandPrimary : null,
                      size: 20),
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
            if (!isAd && item.likeUsers.isNotEmpty)
              Text(
                  '♡ ${item.likeUsers.map((user) => user.displayName).join('、')}',
                  style: const TextStyle(
                      color: WeChatColors.socialLink, fontSize: 13)),
            if (!isAd)
              for (final comment in item.comments)
                Text(
                  '${comment.author.displayName}：${comment.text}',
                  key: ValueKey('moment-comment-${comment.id}'),
                  style: const TextStyle(fontSize: 13),
                ),
          ]),
        ),
      ]),
    );
  }
}
