import 'dart:typed_data';

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:image_picker/image_picker.dart';

import '../../ui/components/wechat_scaffold.dart';
import '../../ui/components/user_avatar.dart';

import '../../ui/foundation/wechat_tokens.dart';
import '../../core/business_api_client.dart';
import '../../core/cache/cache_repository.dart';
import '../../ui/moments/wechat_moment_tile.dart';
import '../../ui/moments/wechat_moment_viewer.dart';
import '../../ui/moments/moment_media_cache.dart';
import 'moment_models.dart';
import 'moment_composer_page.dart';
import '../matrix/profile_repository.dart';

final class MomentsPage extends StatefulWidget {
  /// BUG 1：朋友圈不再自建资料缓存——必须注入全局唯一 ProfileRepository。
  const MomentsPage(
      {super.key,
      required this.api,
      required this.identityCache,
      this.onPostsDisplayed,
      this.unreadChanges})
      : _preparedAccount = null;

  const MomentsPage._prepared({
    super.key,
    required this.api,
    required this.identityCache,
    required String? account,
    this.onPostsDisplayed,
    this.unreadChanges,
  }) : _preparedAccount = account;

  /// Resolve the session and warm disk metadata before navigation. Only this
  /// private construction path can authorize synchronous account-cache paint.
  static Future<MomentsPage> prepare({
    Key? key,
    required BusinessApiClient api,
    required ProfileRepository identityCache,
    void Function(Iterable<String> ids)? onPostsDisplayed,
    Listenable? unreadChanges,
  }) async {
    String? account;
    try {
      final matrixId = await api.currentMatrixUserId();
      if (matrixId != null &&
          matrixId.isNotEmpty &&
          identityCache.accountKey == 'matrix:$matrixId') {
        await CacheRepository.instance();
        // Storage initialization can yield. Revalidate immediately before
        // returning the page so an account switch cannot authorize old data.
        if (await api.currentMatrixUserId() == matrixId) {
          account = 'matrix:$matrixId';
        }
      }
    } catch (_) {
      // No identity or storage: the safe default performs async loading.
    }
    return MomentsPage._prepared(
        key: key,
        api: api,
        identityCache: identityCache,
        account: account,
        onPostsDisplayed: onPostsDisplayed,
        unreadChanges: unreadChanges);
  }

  final String? _preparedAccount;
  final BusinessApiClient api;
  final ProfileRepository identityCache;
  final void Function(Iterable<String> ids)? onPostsDisplayed;
  final Listenable? unreadChanges;
  @override
  State<MomentsPage> createState() => _MomentsPageState();
}

enum _ConfirmedMomentWrite { likes, comments, deletion }

final class _MomentsPageState extends State<MomentsPage> {
  final _itemOverrides = <String, MomentItem>{};
  final _pendingLikeIds = <String>{};
  final _postKeys = <String, GlobalKey>{};
  final _feedScroll = ScrollController();

  void _unreadChanged() => WidgetsBinding.instance
      .addPostFrameCallback((_) => _reportVisiblePosts());

  void _reportVisiblePosts() {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    final size = MediaQuery.sizeOf(context);
    final ids = <String>[];
    for (final entry in _postKeys.entries) {
      final box = entry.value.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      if (top < size.height && top + box.size.height > 100) ids.add(entry.key);
    }
    if (ids.isNotEmpty) widget.onPostsDisplayed?.call(ids);
  }

  /// 乐观删除：pending 期间从 Feed 剔除，失败回滚恢复。
  final _deletedIds = <String>{};
  Map<String, dynamic>? _feedData;
  MomentsCache? _moments;
  String? _accountKey;
  String? _viewerUserId;
  int _feedRequest = 0;
  int _preferencesRequest = 0;
  int _mutation = 0;
  int _accountEpoch = 0;
  bool _loadingMore = false;

  Future<void> _loadMorePosts() async {
    if (_loadingMore) return;
    final current = _feedData;
    if (current == null) return;
    final request = _feedRequest;
    final mutation = _mutation;
    final epoch = _accountEpoch;
    final cursor = current['next_cursor'] as String?;
    if (!mounted || cursor == null) return;
    setState(() => _loadingMore = true);
    try {
      final next = await widget.api.momentsFeed(mode: 'latest', cursor: cursor);
      final sameAccount = await _stillSameAccount();
      if (!mounted ||
          !sameAccount ||
          epoch != _accountEpoch ||
          request != _feedRequest ||
          mutation != _mutation) {
        return;
      }
      final merged = <String, dynamic>{
        for (final item in [
          ...(current['items'] as List? ?? []),
          ...(next['items'] as List? ?? [])
        ])
          (item as Map)['id'].toString(): item,
      };
      setState(() => _feedData = {...next, 'items': merged.values.toList()});
    } catch (_) {
      if (mounted && epoch == _accountEpoch) {
        setState(() => _interactionError = '加载更多失败，请重试');
      }
    } finally {
      if (mounted && epoch == _accountEpoch) {
        setState(() => _loadingMore = false);
      }
    }
  }

  String? _coverUrl;
  String? _coverCacheKey;
  String? _interactionError;
  String? _identityError;
  ProfileRepository get _identityCache => widget.identityCache;

  @override
  void initState() {
    super.initState();
    _feedScroll.addListener(_reportVisiblePosts);
    widget.unreadChanges?.addListener(_unreadChanged);
    _identityCache.addListener(_identityChanged);
    _startAccount();
  }

  void _startAccount() {
    ++_accountEpoch;
    ++_feedRequest;
    ++_preferencesRequest;
    _itemOverrides.clear();
    _pendingLikeIds.clear();
    _deletedIds.clear();
    _postKeys.clear();
    _feedData = null;
    _moments = null;
    _accountKey = null;
    _viewerUserId = null;
    _coverUrl = null;
    _coverCacheKey = null;
    _interactionError = null;
    _identityError = null;
    _loadingMore = false;
    final knownAccount = widget._preparedAccount;
    if (knownAccount != null) {
      _accountKey = knownAccount;
      _moments = CacheRepository.current?.momentsFor(knownAccount);
      _feedData = _moments?.snapshot;
      _coverUrl = _moments?.preferencesSnapshot?['cover_url']?.toString();
      _coverCacheKey =
          _moments?.preferencesSnapshot?['cover_cache_key']?.toString();
    }
    _loadIdentity();
    unawaited(_initializeFeed());
  }

  @override
  void didUpdateWidget(covariant MomentsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.unreadChanges != widget.unreadChanges) {
      oldWidget.unreadChanges?.removeListener(_unreadChanged);
      widget.unreadChanges?.addListener(_unreadChanged);
    }
    if (oldWidget.identityCache != widget.identityCache ||
        oldWidget.api != widget.api ||
        oldWidget._preparedAccount != widget._preparedAccount) {
      oldWidget.identityCache.removeListener(_identityChanged);
      _identityCache.addListener(_identityChanged);
      _startAccount();
    }
  }

  Future<void> _loadIdentity() async {
    final epoch = _accountEpoch;
    if (mounted) setState(() => _identityError = null);
    try {
      await _identityCache.preload();
    } catch (_) {
      if (mounted && epoch == _accountEpoch && _identityCache.profile == null) {
        setState(() => _identityError = '资料加载失败');
      }
    }
  }

  Future<void> _loadPreferences() async {
    final request = ++_preferencesRequest;
    final cache = _moments;
    final ticket = cache?.beginPreferencesRefresh();
    try {
      final value = await widget.api.momentsPreferences();
      final sameAccount = await _stillSameAccount();
      if (!mounted ||
          !sameAccount ||
          request != _preferencesRequest ||
          (ticket != null && !cache!.preferencesAreCurrent(ticket))) {
        return;
      }
      if (cache != null) {
        unawaited(cache.savePreferences(value).catchError((Object _) {}));
      }
      setState(() {
        _coverUrl = value['cover_url']?.toString();
        _coverCacheKey = value['cover_cache_key']?.toString();
      });
    } catch (_) {
      if (mounted && request == _preferencesRequest) {
        setState(() => _interactionError = '封面加载失败，请重试');
      }
    }
  }

  void _identityChanged() {
    if (mounted) setState(() {});
  }

  void _reloadFeed() {
    if (!mounted) return;
    setState(() => _interactionError = null);
    unawaited(_refreshFeed());
  }

  Future<void> _initializeFeed() async {
    final epoch = _accountEpoch;
    final knownAccount = _identityCache.accountKey;
    final resolved = await _accountCacheKey();
    if (!mounted || epoch != _accountEpoch) return;
    // A projection supplied for another session cannot authorize cache use.
    if (knownAccount != null && resolved != null && knownAccount != resolved) {
      setState(() {
        _feedData = null;
        _coverUrl = null;
        _coverCacheKey = null;
      });
      _moments = null;
      return;
    }
    _accountKey = resolved;
    if (resolved == null) {
      _moments = null;
      setState(() {
        _feedData = null;
        _coverUrl = null;
        _coverCacheKey = null;
      });
    }
    try {
      final repository = await CacheRepository.instance();
      final account = _accountKey;
      if (epoch != _accountEpoch) return;
      if (account != null) _moments = repository.momentsFor(account);
    } catch (_) {
      // Persistence unavailable: authenticated network loading still works.
    }
    if (!mounted || epoch != _accountEpoch) return;
    setState(() {
      _feedData ??= _moments?.snapshot;
      if (_coverUrl == null) {
        _coverUrl = _moments?.preferencesSnapshot?['cover_url']?.toString();
        _coverCacheKey =
            _moments?.preferencesSnapshot?['cover_cache_key']?.toString();
      }
    });
    unawaited(_loadViewerUserId());
    unawaited(_loadPreferences());
    await _refreshFeed();
  }

  Future<void> _loadViewerUserId() async {
    final epoch = _accountEpoch;
    try {
      final userId = await widget.api.currentUserId();
      final sameAccount = await _stillSameAccount();
      if (mounted && sameAccount && epoch == _accountEpoch) {
        _viewerUserId = userId;
      }
    } catch (_) {
      // Never invent an authenticated business ID for an optimistic name.
    }
  }

  Future<String?> _accountCacheKey() async {
    try {
      final matrixUserId = await widget.api.currentMatrixUserId();
      if (matrixUserId != null && matrixUserId.isNotEmpty) {
        return 'matrix:$matrixUserId';
      }
    } catch (_) {}
    return null;
  }

  Future<bool> _stillSameAccount() async {
    final current = await _accountCacheKey();
    return current == _accountKey;
  }

  Future<void> _refreshFeed() async {
    final request = ++_feedRequest;
    final mutation = _mutation;
    final cache = _moments;
    final ticket = cache?.beginRefresh();
    try {
      final fresh = await widget.api.momentsFeed(mode: 'latest');
      final sameAccount = await _stillSameAccount();
      if (!mounted ||
          !sameAccount ||
          request != _feedRequest ||
          mutation != _mutation ||
          (ticket != null && !cache!.isCurrent(ticket))) {
        return;
      }
      // Pending local edits remain overlays; a successful write invalidates
      // this request before it can replace the confirmed cached state.
      if (cache != null) unawaited(cache.save(fresh).catchError((Object _) {}));
      setState(() {
        _feedData = fresh;
        _itemOverrides.removeWhere((id, _) => !_pendingLikeIds.contains(id));
      });
    } catch (_) {
      // 后台刷新失败保持缓存首绘内容，不打断浏览。
    }
  }

  Future<void> _persistItem(
      MomentItem item, _ConfirmedMomentWrite write) async {
    final epoch = _accountEpoch;
    if (!await _stillSameAccount() || epoch != _accountEpoch) return;
    ++_mutation;
    Map<String, dynamic> updated(Map<String, dynamic> source) {
      final items = <Object?>[];
      for (final raw in source['items'] as List? ?? const []) {
        if (raw is! Map || raw['id']?.toString() != item.id) {
          items.add(raw);
        } else if (write != _ConfirmedMomentWrite.deletion) {
          items.add({
            ...raw,
            if (write == _ConfirmedMomentWrite.likes) ...{
              'viewer_has_liked': item.liked,
              'like_count': item.likeCount,
              'like_users':
                  item.likeUsers.map((user) => user.toJson()).toList(),
            },
            if (write == _ConfirmedMomentWrite.comments)
              'comments':
                  item.comments.map((comment) => comment.toJson()).toList(),
          });
        }
      }
      return {...source, 'items': items};
    }

    final cache = _moments;
    final cached = cache?.snapshot;
    if (cache != null && cached != null) {
      unawaited(cache.save(updated(cached)).catchError((Object _) {}));
    }
    // The disk snapshot contains only the first page; keep loaded older pages
    // in the current view instead of replacing them with that shorter snapshot.
    final displayed = _feedData;
    if (mounted && displayed != null) {
      setState(() => _feedData = updated(displayed));
    }
  }

  @override
  void dispose() {
    _feedScroll.dispose();
    widget.unreadChanges?.removeListener(_unreadChanged);
    _identityCache.removeListener(_identityChanged);
    super.dispose();
  }

  Future<void> _toggleLike(MomentItem item) async {
    if (_pendingLikeIds.contains(item.id)) return;
    final epoch = _accountEpoch;
    final profile = _identityCache.profile;
    final userId = _viewerUserId;
    final likeUsers = [...item.likeUsers];
    if (userId != null && userId.isNotEmpty) {
      likeUsers.removeWhere((user) => user.userId == userId);
      if (!item.liked && profile != null) {
        likeUsers.add(MomentAuthor(
            userId: userId,
            username: profile.username,
            nickname: profile.nickname,
            displayName: profile.nickname.trim().isEmpty
                ? profile.username
                : profile.nickname,
            avatarUrl: profile.avatarUrl));
      }
    }
    final optimistic = item.copyWith(
      liked: !item.liked,
      likeUsers: likeUsers,
      likeCount: item.liked
          ? (item.likeCount > 0 ? item.likeCount - 1 : 0)
          : item.likeCount + 1,
    );
    setState(() {
      _pendingLikeIds.add(item.id);
      _itemOverrides[item.id] = optimistic;
      _interactionError = null;
    });
    try {
      if (item.liked) {
        await widget.api.unlikeMoment(item.id);
      } else {
        await widget.api.likeMoment(item.id);
      }
      if (epoch != _accountEpoch) return;
      var current = _itemOverrides[item.id] ?? optimistic;
      if (userId == null || profile == null) {
        // The secure session/profile can still be loading on a cached first
        // frame. Keep the immediate heart/count, but obtain names from the
        // authenticated projection instead of fabricating a business user ID.
        try {
          final detail = await widget.api.momentDetail(item.id);
          if (epoch != _accountEpoch) return;
          final confirmed = MomentItem.fromJson(detail);
          current = (_itemOverrides[item.id] ?? current).copyWith(
              liked: confirmed.liked,
              likeCount: confirmed.likeCount,
              likeUsers: confirmed.likeUsers);
          if (mounted) setState(() => _itemOverrides[item.id] = current);
        } catch (_) {
          // The write succeeded. A later feed refresh can fill missing names.
        }
      }
      await _persistItem(current, _ConfirmedMomentWrite.likes);
    } catch (error) {
      if (!mounted || epoch != _accountEpoch) return;
      setState(() {
        // Roll back only this operation. A comment may have been confirmed
        // while the like was pending and must remain visible.
        _itemOverrides[item.id] = (_itemOverrides[item.id] ?? item).copyWith(
          liked: item.liked,
          likeCount: item.likeCount,
          likeUsers: item.likeUsers,
        );
        _interactionError =
            error is BusinessApiException ? error.message : '点赞同步失败，请重试';
      });
    } finally {
      if (mounted && epoch == _accountEpoch) {
        setState(() => _pendingLikeIds.remove(item.id));
      }
    }
  }

  /// 删除入口仅对作者可见（PRD 隐私边界：非作者不可删除他人朋友圈）。
  bool _canDelete(MomentItem item) {
    if (item.kind == 'AD') return false;
    final username = _identityCache.profile?.username.trim();
    return username != null &&
        username.isNotEmpty &&
        item.author.username.trim() == username;
  }

  Future<void> _confirmDelete(MomentItem item) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: const Text('删除这条朋友圈？'),
        content: const Text('删除后不可恢复。'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            key: const Key('moment-delete-confirm'),
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _deleteMoment(item);
  }

  /// 乐观删除 + 失败回滚（复用点赞的乐观更新模式）：
  /// 确认后立即从 Feed 剔除 → 调用删除 API → 失败恢复条目并提示；
  /// 成功则同步内存 Feed 与磁盘缓存（避免缓存首绘把已删条目又画回来）。
  Future<void> _deleteMoment(MomentItem item) async {
    if (_deletedIds.contains(item.id)) return;
    final epoch = _accountEpoch;
    setState(() {
      _deletedIds.add(item.id);
      _interactionError = null;
    });
    try {
      await widget.api.deleteMoment(item.id);
      if (epoch != _accountEpoch) return;
      await _persistItem(item, _ConfirmedMomentWrite.deletion);
      if (mounted) {
        setState(() {
          _itemOverrides.remove(item.id);
        });
      }
    } catch (error) {
      if (!mounted || epoch != _accountEpoch) return;
      setState(() {
        _deletedIds.remove(item.id);
        _interactionError =
            error is BusinessApiException ? error.message : '删除失败，请重试';
      });
    }
  }

  Future<void> _showComment(BuildContext context, MomentItem item) async {
    final epoch = _accountEpoch;
    final controller = TextEditingController();
    await showCupertinoDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
              builder: (dialogContext, setDialogState) {
                var submitting = false;
                String? errorMessage;
                return StatefulBuilder(
                  builder: (dialogContext, updateDialog) =>
                      CupertinoAlertDialog(
                    title: const Text('评论'),
                    content: Column(children: [
                      Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: CupertinoTextField(
                            key: const Key('moment-comment-input'),
                            controller: controller,
                            placeholder: '说点什么…',
                            onChanged: (_) => updateDialog(() {}),
                          )),
                      if (errorMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(errorMessage!,
                              style: const TextStyle(
                                  color: CupertinoColors.systemRed)),
                        ),
                    ]),
                    actions: [
                      CupertinoDialogAction(
                          onPressed: submitting
                              ? null
                              : () => Navigator.pop(dialogContext),
                          child: const Text('取消')),
                      CupertinoDialogAction(
                          key: const Key('moment-comment-submit'),
                          onPressed: submitting ||
                                  controller.text.trim().isEmpty
                              ? null
                              : () async {
                                  updateDialog(() {
                                    submitting = true;
                                    errorMessage = null;
                                  });
                                  try {
                                    final response = await widget.api
                                        .commentMoment(
                                            item.id, controller.text.trim());
                                    final comment =
                                        MomentCommentView.fromJson(response);
                                    if (mounted && epoch == _accountEpoch) {
                                      setState(() {
                                        final current =
                                            _itemOverrides[item.id] ?? item;
                                        _itemOverrides[item.id] =
                                            current.copyWith(comments: [
                                          ...current.comments,
                                          comment,
                                        ]);
                                      });
                                      await _persistItem(
                                          _itemOverrides[item.id]!,
                                          _ConfirmedMomentWrite.comments);
                                    }
                                    if (dialogContext.mounted) {
                                      Navigator.pop(dialogContext);
                                    }
                                  } catch (error) {
                                    if (!dialogContext.mounted) return;
                                    updateDialog(() {
                                      submitting = false;
                                      errorMessage =
                                          error is BusinessApiException
                                              ? error.message
                                              : '评论提交失败，请重试';
                                    });
                                  }
                                },
                          child: submitting
                              ? const CupertinoActivityIndicator()
                              : const Text('发送'))
                    ],
                  ),
                );
              },
            ));
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
            backgroundColor: WeChatColors.navigationBackground(context),
            automaticBackgroundVisibility: false,
            enableBackgroundFilterBlur: false,
            middle: const Text('朋友圈'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: () => Navigator.push(
                      context,
                      CupertinoPageRoute(
                          builder: (_) =>
                              MomentsSettingsPage(api: widget.api))),
                  child: const Icon(CupertinoIcons.settings)),
              CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: () async {
                    final didPublish = await Navigator.push<bool>(
                      context,
                      CupertinoPageRoute(
                        builder: (_) => MomentComposerPage(api: widget.api),
                      ),
                    );
                    if (didPublish == true) _reloadFeed();
                  },
                  child: const Icon(CupertinoIcons.camera))
            ])),
        child: SafeArea(child: Builder(builder: (_) {
          final items = (_feedData?['items'] as List?) ?? const [];
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _reportVisiblePosts());
          return ListView(controller: _feedScroll, children: [
            if (_interactionError != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _interactionError!,
                  key: const Key('moment-interaction-error'),
                  style: const TextStyle(color: CupertinoColors.systemRed),
                ),
              ),
            GestureDetector(
                key: const Key('moment-cover-header'),
                onTap: _openCover,
                child: Container(
                    key: ValueKey(_coverUrl),
                    height: 200,
                    decoration: BoxDecoration(
                        color: const Color(0xff4c4c4c),
                        image: _coverUrl == null
                            ? null
                            : DecorationImage(
                                image: MomentMediaCache.imageProvider(
                                    _coverUrl!,
                                    cacheKey: _coverCacheKey,
                                    accountKey: _accountKey,
                                    trustedOrigin: widget.api.baseUri.origin),
                                fit: BoxFit.cover,
                                onError: (_, __) {})),
                    alignment: Alignment.bottomRight,
                    padding: const EdgeInsets.all(16),
                    child: _ownerIdentity())),
            for (final m in items)
              Builder(builder: (_) {
                final parsed =
                    MomentItem.fromJson(Map<String, dynamic>.from(m as Map));
                if (_deletedIds.contains(parsed.id)) {
                  return const SizedBox.shrink();
                }
                final item = _itemOverrides[parsed.id] ?? parsed;
                return WeChatMomentTile(
                  key: _postKeys.putIfAbsent(item.id, GlobalKey.new),
                  item: item,
                  mediaAccountKey: _accountKey,
                  mediaOrigin: widget.api.baseUri.origin,
                  onLike: _pendingLikeIds.contains(item.id)
                      ? null
                      : () => _toggleLike(item),
                  onComment: () => _showComment(context, item),
                  onDelete:
                      _canDelete(item) ? () => _confirmDelete(item) : null,
                );
              }),
            if (_feedData?['next_cursor'] != null)
              CupertinoButton(
                key: const Key('moments-load-more'),
                onPressed: _loadingMore ? null : _loadMorePosts,
                child: _loadingMore
                    ? const CupertinoActivityIndicator()
                    : const Text('加载更多'),
              ),
          ]);
        })),
      );

  Widget _ownerIdentity() {
    final profile = _identityCache.profile;
    if (profile == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const Icon(
            CupertinoIcons.person_crop_circle,
            key: Key('moment-owner-loading-fallback'),
            color: CupertinoColors.white,
            size: 64,
          ),
          if (_identityError != null)
            CupertinoButton(
              key: const Key('moment-owner-retry'),
              padding: const EdgeInsets.only(top: 4),
              onPressed: _loadIdentity,
              child: Text(
                _identityError!,
                style: const TextStyle(color: CupertinoColors.white),
              ),
            ),
        ],
      );
    }
    final nickname = profile.nickname.trim().isEmpty
        ? profile.username.trim()
        : profile.nickname.trim();
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            nickname,
            key: const Key('moment-owner-nickname'),
            style: const TextStyle(
              color: CupertinoColors.white,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: CupertinoColors.white, width: 2),
            borderRadius: BorderRadius.circular(6),
          ),
          child: UserAvatar(
            key: const Key('moment-owner-avatar'),
            nickname: nickname,
            fallbackSeed: profile.fallbackSeed,
            avatarUrl: profile.avatarUrl,
            diagnosticSource: 'moments-owner',
            size: 64,
          ),
        ),
      ],
    );
  }

  void _openCover() {
    Navigator.push(
      context,
      CupertinoPageRoute(
        builder: (_) => WeChatMomentCoverViewer(
          url: _coverUrl,
          cacheKey: _coverCacheKey,
          mediaAccountKey: _accountKey,
          mediaOrigin: widget.api.baseUri.origin,
          cacheKeyForUrl: (url) => url == _coverUrl ? _coverCacheKey : null,
          onChangeCover: _changeCover,
        ),
      ),
    );
  }

  Future<String?> _changeCover(ValueChanged<Uint8List> onPreview) async {
    final epoch = _accountEpoch;
    final api = widget.api;
    final image = await ImagePicker()
        .pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (image == null) return null;
    if (epoch != _accountEpoch) return null;
    final bytes = await image.readAsBytes();
    onPreview(bytes);
    final extension = image.name.toLowerCase().split('.').last;
    final mimeType = extension == 'png'
        ? 'image/png'
        : extension == 'webp'
            ? 'image/webp'
            : 'image/jpeg';
    final begun = await api.beginMomentCoverUpload(
        fileName: image.name, mimeType: mimeType, byteSize: bytes.length);
    final uploadId = begun['id'].toString();
    await api.putMomentCoverUpload(uploadId, bytes, mimeType);
    await api.completeMomentCoverUpload(uploadId);
    final saved = await api.setMomentCover(uploadId);
    final coverUrl = saved['cover_url']?.toString();
    if (!await _stillSameAccount() || epoch != _accountEpoch) return null;
    ++_preferencesRequest;
    final cache = _moments;
    if (cache != null) {
      unawaited(cache.savePreferences(
          {...?cache.preferencesSnapshot, ...saved}).catchError((Object _) {}));
    }
    if (mounted) {
      setState(() {
        _coverUrl = coverUrl;
        _coverCacheKey = saved['cover_cache_key']?.toString();
      });
    }
    return coverUrl;
  }
}

final class MomentsSettingsPage extends StatefulWidget {
  const MomentsSettingsPage({super.key, required this.api});
  final BusinessApiClient api;
  @override
  State<MomentsSettingsPage> createState() => _MomentsSettingsState();
}

final class _MomentsSettingsState extends State<MomentsSettingsPage> {
  String range = 'ALL';
  bool personalized = true;
  @override
  void initState() {
    super.initState();
    widget.api.momentsPreferences().then((r) {
      if (mounted) {
        setState(() {
          range = r['history_range'];
          personalized = r['personalized_recommendations'];
        });
      }
    });
  }

  Future<void> save() async {
    await widget.api.updateMomentsPreferences(
        historyRange: range, personalized: personalized);
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
          backgroundColor: WeChatColors.navigationBackground(context),
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: Text('朋友圈权限')),
      child: SafeArea(
          child: ListView(children: [
        CupertinoListSection.insetGrouped(
            header: const Text('允许朋友查看朋友圈的范围'),
            children: [
              for (final item in const {
                'ALL': '全部',
                'SIX_MONTHS': '最近半年',
                'ONE_MONTH': '最近一个月',
                'THREE_DAYS': '最近三天'
              }.entries)
                CupertinoListTile(
                    title: Text(item.value),
                    trailing: range == item.key
                        ? const Icon(CupertinoIcons.check_mark,
                            color: Color(0xff07c160))
                        : null,
                    onTap: () {
                      setState(() => range = item.key);
                      save();
                    })
            ]),
        CupertinoListSection.insetGrouped(children: [
          CupertinoListTile(
              title: const Text('个性化推荐'),
              trailing: CupertinoSwitch(
                  value: personalized,
                  onChanged: (v) {
                    setState(() => personalized = v);
                    save();
                  }))
        ])
      ])));
}
