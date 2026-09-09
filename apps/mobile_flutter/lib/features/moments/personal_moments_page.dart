import 'package:flutter/cupertino.dart';
import '../../core/business_api_client.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/moments/wechat_moment_tile.dart';
import 'moment_models.dart';
import 'moment_detail_page.dart';
import 'moments_privacy_changes.dart';

class PersonalMomentsPage extends StatefulWidget {
  const PersonalMomentsPage(
      {super.key,
      required this.api,
      required this.userId,
      required this.displayName,
      this.initialItems = const []});
  final BusinessApiClient api;
  final String userId, displayName;
  final List<MomentItem> initialItems;
  @override
  State<PersonalMomentsPage> createState() => _PersonalMomentsState();
}

class _PersonalMomentsState extends State<PersonalMomentsPage> {
  late List<MomentItem> _items = widget.initialItems;
  bool _loading = true;
  int _generation = 0;
  final _pendingLikes = <String>{};
  String? _error;
  String _username = '';
  String? _viewerId;
  @override
  void initState() {
    super.initState();
    momentsPrivacyChanges.addListener(_privacyChanged);
    _reload();
    widget.api.currentUserId().then((id) {
      if (mounted) setState(() => _viewerId = id);
    });
    widget.api.loadProfile().then((p) {
      if (mounted) _username = p.username;
    }).catchError((Object _) {});
  }

  @override
  void dispose() {
    momentsPrivacyChanges.removeListener(_privacyChanged);
    super.dispose();
  }

  void _privacyChanged() {
    setState(() {
      _items = [];
      _loading = true;
    });
    _reload();
  }

  Future<void> _reload() async {
    final generation = ++_generation;
    try {
      final response = await widget.api.personalMoments(widget.userId);
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = (response['items'] as List? ?? [])
            .map((e) => MomentItem.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        _error = null;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _items = [];
          _error = '朋友圈加载失败，请重试';
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _open(MomentItem item, [MomentCommentView? comment]) async {
    await Navigator.push(
        context,
        CupertinoPageRoute(
            builder: (_) => MomentDetailPage(
                  api: widget.api,
                  initialItem: item,
                  currentUsername: _username,
                  initialComment: comment,
                  cacheNamespace: 'profile:${widget.userId}',
                )));
    if (mounted) await _reload();
  }

  Future<void> _delete(MomentItem item) async {
    final confirmed = await showCupertinoDialog<bool>(
        context: context,
        builder: (ctx) =>
            CupertinoAlertDialog(title: const Text('删除这条朋友圈？'), actions: [
              CupertinoDialogAction(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消')),
              CupertinoDialogAction(
                  isDestructiveAction: true,
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('删除')),
            ]));
    if (confirmed != true) return;
    try {
      await widget.api.deleteMoment(item.id);
      if (mounted) await _reload();
    } catch (_) {
      if (mounted) setState(() => _error = '删除失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar:
            CupertinoNavigationBar(middle: Text('${widget.displayName}的朋友圈')),
        child: SafeArea(
            child: ListView(children: [
          if (_error != null)
            CupertinoButton(onPressed: _reload, child: Text(_error!)),
          if (_items.isEmpty && _error == null)
            Padding(
                padding: const EdgeInsets.all(40),
                child: Center(
                    child: _loading
                        ? const CupertinoActivityIndicator()
                        : const Text('暂无动态',
                            style:
                                TextStyle(color: CupertinoColors.systemGrey)))),
          for (final item in _items)
            WeChatMomentTile(
              item: item,
              cacheNamespace: 'profile:${widget.userId}',
              onOpen: () => _open(item),
              onComment: () => _open(item),
              onCommentTap: (c) => _open(item, c),
              onLike: _pendingLikes.contains(item.id)
                  ? null
                  : () async {
                      setState(() => _pendingLikes.add(item.id));
                      try {
                        if (item.liked) {
                          await widget.api.unlikeMoment(item.id);
                        } else {
                          await widget.api.likeMoment(item.id);
                        }
                        if (mounted) await _reload();
                      } catch (_) {
                        if (mounted) setState(() => _error = '点赞失败，请重试');
                      } finally {
                        if (mounted) {
                          setState(() => _pendingLikes.remove(item.id));
                        }
                      }
                    },
              onDelete:
                  _viewerId == item.author.userId ? () => _delete(item) : null,
            ),
        ])),
      );
}
