import '../contacts/contact_actions.dart';
import 'moment_visibility_page.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'moments_privacy_changes.dart';
import 'moment_reactions.dart';
import 'moment_person_navigation.dart';
import 'package:flutter/cupertino.dart';
import '../../core/business_api_client.dart';
import '../matrix/profile_repository.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/moments/wechat_moment_tile.dart';
import 'moment_models.dart';
import 'moment_comment_interaction.dart';

enum MomentDetailChange { likes, comments }

class MomentDetailPage extends StatefulWidget {
  const MomentDetailPage({
    super.key,
    required this.api,
    this.identityCache,
    this.contactActions,
    required this.initialItem,
    required this.currentUsername,
    this.onChanged,
    this.onConfirmed,
    this.viewerUserId,
    this.mediaAccountKey,
    this.mediaOrigin,
    this.onReactionChanged,
    this.initialComment,
    this.cacheNamespace = '',
  });
  final BusinessApiClient api;
  final ContactActions? contactActions;
  final Future<void> Function(MomentItem, MomentDetailChange)? onConfirmed;
  final String? mediaAccountKey, mediaOrigin;
  final String? viewerUserId;
  final ProfileRepository? identityCache;
  final MomentItem initialItem;
  final String currentUsername;
  final ValueChanged<MomentItem>? onChanged;
  final ValueChanged<MomentItem>? onReactionChanged;
  final MomentCommentView? initialComment;
  final String cacheNamespace;
  @override
  State<MomentDetailPage> createState() => _MomentDetailState();
}

class _MomentDetailState extends State<MomentDetailPage> {
  late MomentItem item = widget.initialItem;
  int revision = 0;
  bool liking = false;
  bool unavailable = false;
  String? error;
  String? selectedCommentId;
  bool openingPerson = false;
  void _commentDeleted() {
    final change = momentCommentDeletions.value;
    if (change == null ||
        !change.appliesTo(
            widget.api,
            widget.identityCache?.profile?.username ??
                widget.currentUsername) ||
        change.momentId != item.id) {
      return;
    }
    update(change.apply(item));
  }

  @override
  void initState() {
    super.initState();
    momentCommentDeletions.addListener(_commentDeleted);
    widget.identityCache?.addListener(identityChanged);
    momentsPrivacyChanges.addListener(privacyChanged);
    final pending = PendingMomentReaction.find(widget.api, item.id);
    if (pending == null) {
      refresh();
    } else {
      liking = true;
      if (!pending.audienceIsCurrent) refresh();
      pending.result.then((result) {
        if (!mounted) return;
        if (pending.audienceIsCurrent) {
          update(restoreMomentReaction(item, result), reactionsOnly: true);
        }
        setState(() => liking = false);
      });
    }
    if (widget.initialComment != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) tapComment(widget.initialComment!);
      });
    }
  }

  void privacyChanged() {
    if (!mounted) return;
    setState(() {
      unavailable = true;
      error = '动态暂不可见，请重试';
      revision++;
    });
    refresh();
  }

  void identityChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.identityCache?.removeListener(identityChanged);
    momentsPrivacyChanges.removeListener(privacyChanged);
    momentCommentDeletions.removeListener(_commentDeleted);
    super.dispose();
  }

  void update(MomentItem value, {bool reactionsOnly = false}) {
    if (!mounted || unavailable) return;
    setState(() {
      item = value;
      revision++;
    });
    if (reactionsOnly) {
      (widget.onReactionChanged ?? widget.onChanged)?.call(value);
    } else {
      widget.onChanged?.call(value);
    }
  }

  Future<void> refresh() async {
    final generation = revision;
    try {
      final response = await widget.api.momentDetail(item.id);
      if (mounted && generation == revision) {
        unavailable = false;
        error = null;
        update(MomentItem.fromJson(response));
      }
    } on BusinessApiException catch (failure) {
      if (mounted && [401, 403, 404].contains(failure.statusCode)) {
        setState(() {
          unavailable = true;
          error = '动态已不可见';
          revision++;
        });
      }
    } catch (_) {
      /* Preserve the snapshot only on transient network failure. */
    }
  }

  Future<void> comment([MomentCommentView? parent, Rect? anchor]) =>
      interactWithMomentComment(
        context,
        api: widget.api,
        momentId: item.id,
        currentUsername: widget.currentUsername,
        identityCache: widget.identityCache,
        comment: parent,
        longPress: anchor != null,
        anchor: anchor,
        currentItem: () => unavailable ? null : item,
        onChanged: update,
        onConfirmed: (value) async {
          await widget.onConfirmed?.call(value, MomentDetailChange.comments);
        },
        onSelectionChanged: (id) => setState(() => selectedCommentId = id),
        onError: (message) => setState(() => error = message),
      );

  Future<void> tapComment(MomentCommentView value) => comment(value);

  Future<void> like() async {
    if (liking ||
        unavailable ||
        PendingMomentReaction.find(widget.api, item.id) != null) {
      return;
    }
    liking = true;
    final before = item;
    final pending = PendingMomentReaction.begin(widget.api, item.id);
    var succeeded = true;
    update(
      toggleMomentReaction(
        item,
        momentViewer(widget.identityCache,
            username: widget.currentUsername,
            userId: widget.viewerUserId ?? ''),
      ),
      reactionsOnly: true,
    );
    try {
      if (before.liked) {
        await widget.api.unlikeMoment(item.id);
      } else {
        await widget.api.likeMoment(item.id);
      }
      if (pending.audienceIsCurrent && !unavailable) {
        if (widget.viewerUserId == null) {
          try {
            final confirmed =
                MomentItem.fromJson(await widget.api.momentDetail(item.id));
            if (pending.audienceIsCurrent && !unavailable) {
              item = restoreMomentReaction(item, confirmed);
              update(item, reactionsOnly: true);
            }
          } catch (_) {/* The write succeeded; keep the current projection. */}
        }
        await widget.onConfirmed?.call(item, MomentDetailChange.likes);
      }
    } catch (_) {
      succeeded = false;
      if (!pending.audienceIsCurrent) return;
      if (!mounted) {
        (widget.onReactionChanged ?? widget.onChanged)?.call(
          restoreMomentReaction(item, before),
        );
      }
      if (mounted) {
        update(restoreMomentReaction(item, before), reactionsOnly: true);
        setState(() => error = '点赞失败，请重试');
      }
    } finally {
      pending.finish(widget.api, succeeded ? item : before);
      if (mounted) setState(() => liking = false);
    }
  }

  Future<void> openPerson(MomentAuthor person) async {
    if (openingPerson || unavailable) return;
    openingPerson = true;
    try {
      await openMomentPerson(
        context,
        contactActions: widget.contactActions,
        api: widget.api,
        identityCache: widget.identityCache,
        person: person,
      );
    } catch (_) {
      if (mounted) setState(() => error = '资料加载失败，请重试');
    } finally {
      openingPerson = false;
    }
  }

  /// 作者本人：单条修改可见范围（谁可以看），样式与发布页一致。
  Future<void> _editVisibility() async {
    final current = item.visibilitySelection;
    if (current == null || widget.viewerUserId != item.author.userId) return;
    final selection = await Navigator.push<MomentVisibilitySelection>(
      context,
      CupertinoPageRoute(
        builder: (_) => MomentVisibilityPage(
          api: widget.api,
          initialSelection: current,
        ),
      ),
    );
    if (selection == null || !mounted) return;
    try {
      final updated = await widget.api.updateMomentVisibility(
        item.id,
        {
          'visibility': selection.visibility,
          'include_user_ids':
              selection.visibility == 'INCLUDE' ? selection.userIds.toList() : const [],
          'exclude_user_ids':
              selection.visibility == 'EXCLUDE' ? selection.userIds.toList() : const [],
          'include_tag_ids':
              selection.visibility == 'INCLUDE' ? selection.tagIds.toList() : const [],
          'exclude_tag_ids':
              selection.visibility == 'EXCLUDE' ? selection.tagIds.toList() : const [],
        },
      );
      if (!mounted) return;
      setState(() => item = MomentItem.fromJson(updated));
      widget.onChanged?.call(item);
    } catch (_) {
      if (mounted) {
        showCupertinoDialog<void>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
            title: const Text('可见范围修改失败'),
            content: const Text('请检查网络后重试'),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
          middle: const Text('详情'),
          trailing: item.visibilitySelection != null &&
                  widget.viewerUserId == item.author.userId
              ? CupertinoButton(
                  key: const Key('moment-detail-more'),
                  padding: EdgeInsets.zero,
                  onPressed: _editVisibility,
                  child: Icon(CupertinoIcons.ellipsis,
                      size: 20,
                      color: WeChatColors.resolveTextPrimary(context)),
                )
              : null,
        ),
        child: SafeArea(
          child: ListView(
            children: [
              if (!unavailable)
                WeChatMomentTile(
                  identityCache: widget.identityCache,
                  item: visibleMomentReactions(
                    item,
                    widget.identityCache,
                    username: widget.currentUsername,
                  ),
                  detailMode: true,
                  selectedCommentId: selectedCommentId,
                  onPersonTap: openPerson,
                  onAuthorTap: () => openPerson(item.author),
                  cacheNamespace: widget.cacheNamespace,
                  mediaAccountKey: widget.mediaAccountKey,
                  mediaOrigin: widget.mediaOrigin,
                  onLike: liking ? null : like,
                  onComment: comment,
                  onCommentLongPress: (c, anchor) => comment(c, anchor),
                  onCommentTap: tapComment,
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    error!,
                    style: const TextStyle(color: CupertinoColors.systemRed),
                  ),
                ),
              if (unavailable)
                CupertinoButton(onPressed: refresh, child: const Text('重试')),
            ],
          ),
        ),
      );
}
