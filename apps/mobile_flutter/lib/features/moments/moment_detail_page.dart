import 'moments_privacy_changes.dart';
import 'package:flutter/services.dart';
import 'moment_reactions.dart';
import 'moment_person_navigation.dart';
import 'package:flutter/cupertino.dart';
import '../../core/business_api_client.dart';
import '../matrix/profile_repository.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/moments/wechat_moment_tile.dart';
import 'moment_models.dart';
import 'moment_comment_composer.dart';

class MomentDetailPage extends StatefulWidget {
  const MomentDetailPage(
      {super.key,
      required this.api,
      this.identityCache,
      required this.initialItem,
      required this.currentUsername,
      this.onChanged,
      this.onReactionChanged,
      this.initialComment,
      this.cacheNamespace = ''});
  final BusinessApiClient api;
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
  @override
  void initState() {
    super.initState();
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
    } catch (_) {/* Preserve the snapshot only on transient network failure. */}
  }

  Future<void> comment([MomentCommentView? parent]) async {
    if (unavailable) return;
    final result = await showMomentCommentComposer(context,
        identityCache: widget.identityCache,
        api: widget.api,
        momentId: item.id,
        parent: parent);
    if (result != null && mounted) {
      update(
          item.copyWith(comments: mergeMomentComments(item.comments, result)));
    }
  }

  Future<void> tapComment(MomentCommentView value) async {
    final ownUsername =
        widget.identityCache?.profile?.username ?? widget.currentUsername;
    if (ownUsername.isEmpty || value.author.username != ownUsername) {
      setState(() => selectedCommentId = value.id);
      try {
        await comment(value);
      } finally {
        if (mounted) setState(() => selectedCommentId = null);
      }
      return;
    }
    final remove = await showCupertinoModalPopup<bool>(
        context: context,
        builder: (context) => CupertinoActionSheet(
                actions: [
                  CupertinoActionSheetAction(
                      onPressed: () {
                        Navigator.pop(context, false);
                        Clipboard.setData(ClipboardData(text: value.text));
                      },
                      child: const Text('复制')),
                  CupertinoActionSheetAction(
                      isDestructiveAction: true,
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('删除'))
                ],
                cancelButton: CupertinoActionSheetAction(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消'))));
    if (remove != true || !mounted) return;
    try {
      await widget.api.deleteMomentComment(item.id, value.id);
      if (mounted) {
        update(item.copyWith(
            comments: item.comments.where((c) => c.id != value.id).toList()));
      }
    } catch (_) {
      if (mounted) setState(() => error = '删除失败，请重试');
    }
  }

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
                username: widget.currentUsername)),
        reactionsOnly: true);
    try {
      if (before.liked) {
        await widget.api.unlikeMoment(item.id);
      } else {
        await widget.api.likeMoment(item.id);
      }
    } catch (_) {
      succeeded = false;
      if (!pending.audienceIsCurrent) return;
      if (!mounted) {
        (widget.onReactionChanged ?? widget.onChanged)
            ?.call(restoreMomentReaction(item, before));
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
      await openMomentPerson(context,
          api: widget.api, identityCache: widget.identityCache, person: person);
    } catch (_) {
      if (mounted) setState(() => error = '资料加载失败，请重试');
    } finally {
      openingPerson = false;
    }
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: const CupertinoNavigationBar(middle: Text('详情')),
        child: SafeArea(
            child: ListView(children: [
          if (!unavailable)
            WeChatMomentTile(
                identityCache: widget.identityCache,
                item: visibleMomentReactions(item, widget.identityCache,
                    username: widget.currentUsername),
                detailMode: true,
                selectedCommentId: selectedCommentId,
                onPersonTap: openPerson,
                onAuthorTap: () => openPerson(item.author),
                cacheNamespace: widget.cacheNamespace,
                onLike: liking ? null : like,
                onComment: comment,
                onCommentTap: tapComment),
          if (error != null)
            Padding(
                padding: const EdgeInsets.all(12),
                child: Text(error!,
                    style: const TextStyle(color: CupertinoColors.systemRed))),
          if (unavailable)
            CupertinoButton(onPressed: refresh, child: const Text('重试')),
        ])),
      );
}
