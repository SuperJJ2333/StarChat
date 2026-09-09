import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import '../../core/business_api_client.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/moments/wechat_moment_tile.dart';
import 'moment_models.dart';
import 'moment_comment_composer.dart';

enum MomentDetailChange { likes, comments }

class MomentDetailPage extends StatefulWidget {
  const MomentDetailPage(
      {super.key,
      required this.api,
      required this.initialItem,
      required this.currentUsername,
      this.onChanged,
      this.viewer,
      this.onConfirmed,
      this.feedLikePending,
      this.mediaAccountKey,
      this.mediaOrigin,
      this.initialComment,
      this.cacheNamespace = ''});
  final BusinessApiClient api;
  final Future<void> Function(MomentItem, MomentDetailChange)? onConfirmed;
  final ValueListenable<bool>? feedLikePending;
  final String? mediaAccountKey, mediaOrigin;
  final MomentItem initialItem;
  final MomentAuthor? viewer;
  final String currentUsername;
  final ValueChanged<MomentItem>? onChanged;
  final MomentCommentView? initialComment;
  final String cacheNamespace;
  @override
  State<MomentDetailPage> createState() => _MomentDetailState();
}

class _MomentDetailState extends State<MomentDetailPage> {
  late MomentItem item = widget.initialItem;
  int revision = 0;
  bool liking = false;
  String? error;
  @override
  void initState() {
    super.initState();
    widget.feedLikePending?.addListener(feedLikeChanged);
    refresh();
    if (widget.initialComment != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) tapComment(widget.initialComment!);
      });
    }
  }

  void feedLikeChanged() {
    if (!mounted) return;
    setState(() {});
    if (widget.feedLikePending?.value != true) refresh();
  }

  @override
  void dispose() {
    widget.feedLikePending?.removeListener(feedLikeChanged);
    super.dispose();
  }

  void update(MomentItem value) {
    if (!mounted) return;
    setState(() {
      item = value;
      revision++;
    });
    widget.onChanged?.call(value);
  }

  Future<void> refresh() async {
    final generation = revision;
    try {
      final response = await widget.api.momentDetail(item.id);
      if (mounted && generation == revision) {
        update(MomentItem.fromJson(response));
      }
    } catch (_) {/* Keep the already visible snapshot on transient failure. */}
  }

  Future<void> comment([MomentCommentView? parent]) async {
    final result = await showMomentCommentComposer(context,
        api: widget.api, momentId: item.id, parent: parent);
    if (result != null && mounted) {
      update(
          item.copyWith(comments: mergeMomentComments(item.comments, result)));
      await widget.onConfirmed?.call(item, MomentDetailChange.comments);
    }
  }

  Future<void> tapComment(MomentCommentView value) async {
    if (widget.currentUsername.isEmpty ||
        value.author.username != widget.currentUsername) {
      await comment(value);
      return;
    }
    final remove = await showCupertinoModalPopup<bool>(
        context: context,
        builder: (context) => CupertinoActionSheet(
                actions: [
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
      final confirmed = item.copyWith(
          comments: item.comments.where((c) => c.id != value.id).toList());
      update(confirmed);
      await widget.onConfirmed?.call(confirmed, MomentDetailChange.comments);
    } catch (_) {
      if (mounted) setState(() => error = '删除失败，请重试');
    }
  }

  Future<void> like() async {
    if (liking || widget.feedLikePending?.value == true) return;
    liking = true;
    final before = item;
    final viewer = widget.viewer;
    final likeUsers = [...item.likeUsers];
    if (viewer != null) {
      likeUsers.removeWhere((user) => user.userId == viewer.userId);
      if (!before.liked) likeUsers.add(viewer);
    }
    update(item.copyWith(
        likeUsers: likeUsers,
        liked: !item.liked,
        likeCount: (item.likeCount + (item.liked ? -1 : 1)).clamp(0, 1 << 30)));
    try {
      if (before.liked) {
        await widget.api.unlikeMoment(item.id);
      } else {
        await widget.api.likeMoment(item.id);
      }
      var confirmed = item;
      if (viewer == null) {
        try {
          final projection =
              MomentItem.fromJson(await widget.api.momentDetail(item.id));
          confirmed = item.copyWith(
              liked: projection.liked,
              likeCount: projection.likeCount,
              likeUsers: projection.likeUsers);
          update(confirmed);
        } catch (_) {
          // The write succeeded; retain the acknowledged heart/count until
          // a later projection can supply authenticated display names.
        }
      }
      await widget.onConfirmed?.call(confirmed, MomentDetailChange.likes);
    } catch (_) {
      if (mounted) {
        update(item.copyWith(
            liked: before.liked,
            likeCount: before.likeCount,
            likeUsers: before.likeUsers));
        setState(() => error = '点赞失败，请重试');
      }
    } finally {
      if (mounted) setState(() => liking = false);
    }
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: const CupertinoNavigationBar(middle: Text('详情')),
        child: SafeArea(
            child: ListView(children: [
          WeChatMomentTile(
              item: item,
              cacheNamespace: widget.cacheNamespace,
              mediaAccountKey: widget.mediaAccountKey,
              mediaOrigin: widget.mediaOrigin,
              onLike:
                  liking || widget.feedLikePending?.value == true ? null : like,
              onComment: comment,
              onCommentTap: tapComment),
          if (error != null)
            Padding(
                padding: const EdgeInsets.all(12),
                child: Text(error!,
                    style: const TextStyle(color: CupertinoColors.systemRed))),
        ])),
      );
}
