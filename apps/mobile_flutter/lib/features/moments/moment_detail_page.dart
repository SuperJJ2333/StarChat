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
      this.initialComment,
      this.cacheNamespace = ''});
  final BusinessApiClient api;
  final ProfileRepository? identityCache;
  final MomentItem initialItem;
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
  bool unavailable = false;
  String? error;
  @override
  void initState() {
    super.initState();
    refresh();
    if (widget.initialComment != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) tapComment(widget.initialComment!);
      });
    }
  }

  void update(MomentItem value) {
    if (!mounted || unavailable) return;
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
      if (mounted) {
        update(item.copyWith(
            comments: item.comments.where((c) => c.id != value.id).toList()));
      }
    } catch (_) {
      if (mounted) setState(() => error = '删除失败，请重试');
    }
  }

  Future<void> like() async {
    if (liking || unavailable) return;
    liking = true;
    final before = item;
    update(item.copyWith(
        liked: !item.liked,
        likeCount: (item.likeCount + (item.liked ? -1 : 1)).clamp(0, 1 << 30)));
    try {
      if (before.liked) {
        await widget.api.unlikeMoment(item.id);
      } else {
        await widget.api.likeMoment(item.id);
      }
    } catch (_) {
      if (mounted) {
        update(item.copyWith(liked: before.liked, likeCount: before.likeCount));
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
          if (!unavailable)
            WeChatMomentTile(
                identityCache: widget.identityCache,
                item: item,
                cacheNamespace: widget.cacheNamespace,
                onLike: liking ? null : like,
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
