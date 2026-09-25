import 'dart:async';

import '../contacts/contact_actions.dart';
import 'moment_comment_interaction.dart';
import 'moment_reactions.dart';
import 'moment_person_navigation.dart';
import 'package:flutter/cupertino.dart';
import '../../core/business_api_client.dart';
import '../matrix/profile_repository.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/components/wechat_nav_title.dart';
import '../../ui/moments/wechat_moment_tile.dart';
import '../../ui/moments/moment_warning_banner.dart';
import 'moment_models.dart';
import 'moment_detail_page.dart';
import 'moment_interaction_inbox_page.dart';
import 'moments_privacy_changes.dart';
import '../../ui/motion/motion_page_route.dart';

class PersonalMomentsPage extends StatefulWidget {
  const PersonalMomentsPage(
      {super.key,
      required this.api,
      this.identityCache,
      this.contactActions,
      required this.userId,
      required this.displayName,
      this.initialItems = const [],
      this.publishedOnly = false,
      this.onNotificationsChanged});
  final BusinessApiClient api;
  final ContactActions? contactActions;
  final ProfileRepository? identityCache;
  final String userId, displayName;
  final List<MomentItem> initialItems;
  final bool publishedOnly;
  final VoidCallback? onNotificationsChanged;
  @override
  State<PersonalMomentsPage> createState() => _PersonalMomentsState();
}

class _PersonalMomentsState extends State<PersonalMomentsPage> {
  late List<MomentItem> _items = _presented(widget.initialItems);
  bool _loading = true;
  int _generation = 0;
  final _selectedComments = <String, String>{};
  final _pendingLikes = <String>{};
  String? _error;
  String _username = '';
  String? _viewerId;
  String? _mediaAccountKey;
  int _mediaAccountResolution = 0;
  bool _openingPerson = false;
  List<MomentItem> _presented(List<MomentItem> items) => widget.publishedOnly
      ? items
          .where((item) =>
              item.kind != 'AD' &&
              item.author.userId == widget.userId &&
              item.status == 'PUBLISHED')
          .toList(growable: false)
      : items;
  void _commentDeleted() {
    final change = momentCommentDeletions.value;
    if (change == null ||
        !change.appliesTo(
            widget.api, widget.identityCache?.profile?.username ?? _username)) {
      return;
    }
    setState(() {
      _generation++;
      _items = _items.map(change.apply).toList();
    });
  }

  @override
  void initState() {
    super.initState();
    momentCommentDeletions.addListener(_commentDeleted);
    widget.identityCache?.addListener(_identityChanged);
    momentsPrivacyChanges.addListener(_privacyChanged);
    unawaited(_resolveMediaAccountKey());
    _reload();
    unawaited(_resolveViewerId());
    widget.api.loadProfile().then((p) {
      if (mounted) _username = p.username;
    }).catchError((Object _) {});
  }

  @override
  void dispose() {
    momentsPrivacyChanges.removeListener(_privacyChanged);
    widget.identityCache?.removeListener(_identityChanged);
    momentCommentDeletions.removeListener(_commentDeleted);
    super.dispose();
  }

  void _identityChanged() {
    if (!mounted) return;
    setState(() {});
    unawaited(_resolveMediaAccountKey());
  }

  @override
  void didUpdateWidget(covariant PersonalMomentsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identityCache != widget.identityCache) {
      oldWidget.identityCache?.removeListener(_identityChanged);
      widget.identityCache?.addListener(_identityChanged);
    }
    if (oldWidget.api != widget.api ||
        oldWidget.identityCache != widget.identityCache) {
      _mediaAccountKey = null;
      unawaited(_resolveMediaAccountKey());
    }
    if (oldWidget.api != widget.api ||
        oldWidget.userId != widget.userId ||
        oldWidget.publishedOnly != widget.publishedOnly) {
      _items = _presented(widget.initialItems);
      _loading = true;
      _viewerId = null;
      _reload();
      unawaited(_resolveViewerId());
    }
  }

  Future<void> _resolveViewerId() async {
    final api = widget.api;
    final epoch = api.sessionEpoch;
    final userId = widget.userId;
    try {
      final viewerId = await api.currentUserId();
      if (mounted &&
          identical(widget.api, api) &&
          api.sessionEpoch == epoch &&
          widget.userId == userId) {
        setState(() => _viewerId = viewerId);
      }
    } catch (_) {
      // The More action performs a fresh identity check before opening.
    }
  }

  Future<String?> _resolveMediaAccountKey() async {
    final resolution = ++_mediaAccountResolution;
    final api = widget.api;
    String? accountKey;
    try {
      final matrixUserId = await api.currentMatrixUserId();
      if (matrixUserId != null && matrixUserId.isNotEmpty) {
        accountKey = 'matrix:$matrixUserId';
      }
    } catch (_) {
      // An unknown session cannot authorize access to cached media.
    }
    if (!mounted ||
        resolution != _mediaAccountResolution ||
        !identical(widget.api, api)) {
      return null;
    }
    final identityKey = widget.identityCache?.accountKey;
    if (identityKey != null && identityKey != accountKey) {
      accountKey = null;
    }
    if (_mediaAccountKey != accountKey) {
      setState(() => _mediaAccountKey = accountKey);
    }
    return accountKey;
  }

  void _privacyChanged() {
    // 失败不覆盖：可见性变化只需重取，不预先清空已展示的动态（有内容时也不显示
    // 整页加载圈，避免"切换设置 → 页面闪白"）。
    setState(() => _loading = _items.isEmpty);
    unawaited(_resolveMediaAccountKey());
    _reload();
  }

  Future<void> _reload() async {
    final generation = ++_generation;
    try {
      final response = await widget.api.personalMoments(widget.userId);
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = _presented((response['items'] as List? ?? [])
            .map((e) => MomentItem.fromJson(Map<String, dynamic>.from(e)))
            .toList());
        _error = null;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          // 已有动态时保留；只有"从未成功过、没有任何内容"才提示失败。
          if (_items.isEmpty) _error = '朋友圈加载失败，请重试';
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _open(MomentItem item) async {
    final mediaAccountKey = await _resolveMediaAccountKey();
    if (!mounted) return;
    await Navigator.push(
        context,
        MotionPageRoute(
            builder: (_) => MomentDetailPage(
                  contactActions: widget.contactActions,
                  identityCache: widget.identityCache,
                  api: widget.api,
                  initialItem: item,
                  currentUsername:
                      widget.identityCache?.profile?.username ?? _username,
                  onChanged: _updateItem,
                  onReactionChanged: (updated) {
                    final current = _items
                        .where((value) => value.id == updated.id)
                        .firstOrNull;
                    if (current != null) {
                      _updateItem(restoreMomentReaction(current, updated));
                    }
                  },
                  cacheNamespace: 'profile:${widget.userId}',
                  mediaAccountKey: mediaAccountKey,
                  mediaOrigin: widget.api.baseUri.origin,
                )));
  }

  Future<void> _comment(MomentItem item,
          [MomentCommentView? comment, Rect? anchor]) =>
      interactWithMomentComment(context,
          api: widget.api,
          momentId: item.id,
          currentUsername: _username,
          identityCache: widget.identityCache,
          comment: comment,
          longPress: anchor != null,
          anchor: anchor,
          currentItem: () =>
              _items.where((value) => value.id == item.id).firstOrNull,
          onChanged: _updateItem,
          onSelectionChanged: (id) => setState(() {
                if (id == null) {
                  _selectedComments.remove(item.id);
                } else {
                  _selectedComments[item.id] = id;
                }
              }),
          onError: (message) => setState(() => _error = message));

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

  void _updateItem(MomentItem updated) {
    if (!mounted) return;
    setState(() {
      _generation++;
      _items = [
        for (final item in _items)
          if (item.id == updated.id) updated else item
      ];
    });
  }

  Future<void> _like(MomentItem item) async {
    if (PendingMomentReaction.find(widget.api, item.id) != null) return;
    setState(() {
      _pendingLikes.add(item.id);
      _error = null;
    });
    final optimistic = toggleMomentReaction(
        item,
        momentViewer(widget.identityCache,
            username: _username, userId: _viewerId ?? ''));
    final pending = PendingMomentReaction.begin(widget.api, item.id);
    var succeeded = true;
    _updateItem(optimistic);
    try {
      if (item.liked) {
        await widget.api.unlikeMoment(item.id);
      } else {
        await widget.api.likeMoment(item.id);
      }
    } catch (_) {
      succeeded = false;
      if (mounted && pending.audienceIsCurrent) {
        final current = _items.where((i) => i.id == item.id).firstOrNull;
        if (current != null) _updateItem(restoreMomentReaction(current, item));
        setState(() => _error = '点赞失败，请重试');
      }
    } finally {
      pending.finish(widget.api, succeeded ? optimistic : item);
      if (mounted) setState(() => _pendingLikes.remove(item.id));
    }
  }

  Future<void> _openPerson(MomentAuthor person) async {
    if (_openingPerson) return;
    _openingPerson = true;
    try {
      await openMomentPerson(context,
          contactActions: widget.contactActions,
          api: widget.api,
          identityCache: widget.identityCache,
          person: person);
    } catch (_) {
      if (mounted) setState(() => _error = '资料加载失败，请重试');
    } finally {
      _openingPerson = false;
    }
  }

  Future<void> _openNotifications() async {
    final api = widget.api;
    final epoch = api.sessionEpoch;
    final userId = widget.userId;
    String? viewerId;
    try {
      viewerId = await api.currentUserId();
    } catch (_) {
      return;
    }
    if (!mounted ||
        !identical(widget.api, api) ||
        api.sessionEpoch != epoch ||
        widget.userId != userId ||
        viewerId != userId) {
      return;
    }
    final mediaAccountKey = await _resolveMediaAccountKey();
    String? verifiedId;
    try {
      verifiedId = await api.currentUserId();
    } catch (_) {
      return;
    }
    if (!mounted ||
        !identical(widget.api, api) ||
        api.sessionEpoch != epoch ||
        widget.userId != userId ||
        verifiedId != userId) {
      return;
    }
    setState(() => _viewerId = viewerId);
    await Navigator.push(
        context,
        MotionPageRoute(
            builder: (_) => MomentInteractionInboxPage(
                  api: widget.api,
                  identityCache: widget.identityCache,
                  contactActions: widget.contactActions,
                  currentUsername: _username,
                  viewerUserId: viewerId,
                  mediaAccountKey: mediaAccountKey,
                  mediaOrigin: widget.api.baseUri.origin,
                  onNotificationsChanged: widget.onNotificationsChanged,
                )));
    if (mounted && identical(widget.api, api) && api.sessionEpoch == epoch) {
      widget.onNotificationsChanged?.call();
    }
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
            middle: widget.publishedOnly
                ? const Text('我的朋友圈')
                : WeChatNavTitle(
                    '${widget.identityCache?.resolveIdentity(userId: widget.userId, displayName: widget.displayName).displayName ?? widget.displayName}的朋友圈',
                    userId: widget.userId,
                    supportIdentities: widget.api.supportIdentities),
            trailing: widget.publishedOnly
                ? CupertinoButton(
                    key: const Key('personal-moments-more'),
                    padding: EdgeInsets.zero,
                    onPressed: _openNotifications,
                    child: const Icon(CupertinoIcons.ellipsis),
                  )
                : null),
        child: SafeArea(
            child: ListView(children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(children: [
                MomentWarningBanner(message: _error!),
                CupertinoButton(onPressed: _reload, child: const Text('重试')),
              ]),
            ),
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
              supportIdentities: widget.api.supportIdentities,
              identityCache: widget.identityCache,
              item: visibleMomentReactions(item, widget.identityCache,
                  username: _username),
              cacheNamespace: 'profile:${widget.userId}',
              mediaAccountKey: _mediaAccountKey,
              mediaOrigin: widget.api.baseUri.origin,
              onOpen: () => _open(item),
              onAuthorTap: () => _openPerson(item.author),
              onPersonTap: _openPerson,
              selectedCommentId: _selectedComments[item.id],
              onComment: () => _comment(item),
              onCommentLongPress: (c, anchor) => _comment(item, c, anchor),
              onCommentTap: (c) => _comment(item, c),
              onLike:
                  _pendingLikes.contains(item.id) ? null : () => _like(item),
              onDelete:
                  _viewerId == item.author.userId ? () => _delete(item) : null,
            ),
        ])),
      );
}
