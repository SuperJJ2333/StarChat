import 'package:flutter/cupertino.dart';

import '../../features/contacts/user_identity.dart';
import '../../features/moments/moment_models.dart';
import '../chat/emoji_text.dart';
import '../components/user_avatar.dart';
import 'moment_image_provider.dart';
import 'moment_image_viewer_page.dart';
import 'moment_reaction_tokens.dart';

final class WeChatMomentReactions extends StatelessWidget {
  const WeChatMomentReactions(
      {super.key,
      required this.item,
      required this.resolveIdentity,
      this.onPersonTap,
      this.onCommentTap,
      this.selectedCommentId,
      this.detailMode = false,
      this.cacheNamespace = ''});
  final MomentItem item;
  final UserIdentity Function(MomentAuthor) resolveIdentity;
  final ValueChanged<MomentAuthor>? onPersonTap;
  final ValueChanged<MomentCommentView>? onCommentTap;
  final String? selectedCommentId;
  final bool detailMode;
  final String cacheNamespace;

  Widget _person(MomentAuthor author, Widget child, String key) =>
      GestureDetector(
          key: ValueKey(key),
          behavior: HitTestBehavior.opaque,
          onTap: onPersonTap == null ? null : () => onPersonTap!(author),
          child: Semantics(
              button: onPersonTap != null,
              label: resolveIdentity(author).displayName,
              child: child));

  Widget _avatar(MomentAuthor author, String key) {
    final identity = resolveIdentity(author);
    return _person(
        author,
        UserAvatar(
            nickname: identity.displayName,
            fallbackSeed: identity.cacheKey,
            avatarUrl: identity.avatarUrl,
            diagnosticSource: 'moments-reactions',
            size: MomentReactionTokens.avatarSize),
        key);
  }

  Widget _name(MomentAuthor author, String key) => _person(
      author,
      Text(resolveIdentity(author).displayName,
          style: const TextStyle(
              color: MomentReactionTokens.name,
              fontSize: 13,
              fontWeight: FontWeight.w600)),
      key);

  Widget _divider(String key) => Container(
      key: ValueKey(key), height: 1, color: MomentReactionTokens.divider);

  @override
  Widget build(BuildContext context) {
    if (item.likeUsers.isEmpty && item.comments.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
        key: const Key('moment-reactions'),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
            color: MomentReactionTokens.background,
            borderRadius: BorderRadius.circular(MomentReactionTokens.radius)),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (item.likeUsers.isNotEmpty)
            Padding(
                padding: const EdgeInsets.all(MomentReactionTokens.feedPadding),
                child: Row(children: [
                  const Icon(CupertinoIcons.heart_fill,
                      color: MomentReactionTokens.name, size: 15),
                  const SizedBox(width: 8),
                  Expanded(
                      child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(children: [
                            for (final person in item.likeUsers)
                              Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: _avatar(
                                      person, 'moment-liker-${person.userId}'))
                          ]))),
                ])),
          if (item.likeUsers.isNotEmpty && item.comments.isNotEmpty)
            _divider('moment-likes-divider'),
          for (var i = 0; i < item.comments.length; i++) ...[
            if (i > 0)
              _divider('moment-comment-divider-${item.comments[i].id}'),
            _comment(context, item.comments[i]),
          ],
        ]));
  }

  Widget _comment(BuildContext context, MomentCommentView comment) =>
      GestureDetector(
          key: ValueKey('moment-comment-${comment.id}'),
          behavior: HitTestBehavior.opaque,
          onTap: onCommentTap == null ? null : () => onCommentTap!(comment),
          child: Container(
              key: ValueKey('moment-comment-surface-${comment.id}'),
              color: selectedCommentId == comment.id
                  ? MomentReactionTokens.selected
                  : null,
              padding: EdgeInsets.all(detailMode
                  ? MomentReactionTokens.detailPadding
                  : MomentReactionTokens.feedPadding),
              child:
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _avatar(comment.author, 'moment-comment-avatar-${comment.id}'),
                const SizedBox(width: 8),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                                child: _name(comment.author,
                                    'moment-comment-name-${comment.id}')),
                            if (comment.createdAt != null) ...[
                              const SizedBox(width: 6),
                              Flexible(
                                  child: Align(
                                      alignment: Alignment.topRight,
                                      child: Text(
                                          formatMomentTime(comment.createdAt!),
                                          key: ValueKey(
                                              'moment-comment-time-${comment.id}'),
                                          textAlign: TextAlign.right,
                                          style: const TextStyle(
                                              color: MomentReactionTokens.muted,
                                              fontSize: 11)))),
                            ],
                          ]),
                      const SizedBox(height: 4),
                      if (comment.parentAuthor != null)
                        Wrap(children: [
                          const Text('回复 ',
                              style: TextStyle(
                                  color: MomentReactionTokens.muted,
                                  fontSize: 13)),
                          _name(comment.parentAuthor!,
                              'moment-comment-parent-${comment.id}'),
                        ]),
                      Text.rich(
                          TextSpan(children: [
                            ...?buildEmojiInlineSpans(comment.text,
                                fontSize: 13),
                            if (buildEmojiInlineSpans(comment.text,
                                    fontSize: 13) ==
                                null)
                              TextSpan(text: comment.text),
                            for (var i = 0; i < comment.images.length; i++)
                              WidgetSpan(
                                  alignment: PlaceholderAlignment.middle,
                                  child: GestureDetector(
                                      onTap: () => Navigator.push(
                                          context,
                                          CupertinoPageRoute(
                                              builder: (_) =>
                                                  MomentImageViewerPage(
                                                      imageUrls: comment.images,
                                                      initialIndex: i,
                                                      imageCacheKeys: comment
                                                          .imageCacheKeys,
                                                      cacheNamespace:
                                                          cacheNamespace))),
                                      child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 2),
                                          child: Image(
                                              image: momentImageProvider(
                                                  comment.images[i],
                                                  momentImageKey(
                                                      comment.imageCacheKeys, i),
                                                  cacheNamespace),
                                              width: 22,
                                              height: 22,
                                              fit: BoxFit.cover,
                                              gaplessPlayback: true,
                                              errorBuilder: (_, __, ___) => const Icon(CupertinoIcons.photo, size: 22, color: MomentReactionTokens.muted))))),
                          ]),
                          style: const TextStyle(
                              color: MomentReactionTokens.text,
                              fontSize: 13,
                              height: 1.5)),
                    ])),
              ])));
}
