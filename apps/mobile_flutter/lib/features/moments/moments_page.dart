import '../contacts/contact_actions.dart';
export 'moments_settings_page.dart';
import 'moments_settings_page.dart';
import 'moments_privacy_changes.dart';
import 'moment_person_navigation.dart';
import 'moment_reactions.dart';
import 'dart:typed_data';

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
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
import 'moment_detail_page.dart';
import 'moment_comment_interaction.dart';
import 'moment_composer_page.dart';
import '../matrix/profile_repository.dart';

final class MomentsPage extends StatefulWidget {
  /// BUG 1：朋友圈不再自建资料缓存——必须注入全局唯一 ProfileRepository。
  const MomentsPage({
    super.key,
    required this.api,
    required this.identityCache,
    this.contactActions,
    this.onPostsDisplayed,
    this.unreadChanges,
  }) : _preparedAccount = null;

  const MomentsPage._prepared({
    super.key,
    required this.api,
    required this.identityCache,
    this.contactActions,
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
    ContactActions? contactActions,
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
      contactActions: contactActions,
      account: account,
      onPostsDisplayed: onPostsDisplayed,
      unreadChanges: unreadChanges,
    );
  }

  final String? _preparedAccount;
  final BusinessApiClient api;
  final ContactActions? contactActions;
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
  final _selectedComments = <String, String>{};
  final _postKeys = <String, GlobalKey>{};
  final _feedScroll = ScrollController();

  void _unreadChanged() => WidgetsBinding.instance.addPostFrameCallback(
        (_) => _reportVisiblePosts(),
      );

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
  Future<void>? _invalidationsReady;
  String? _accountKey;
  String? _viewerUserId;
  int _feedRequest = 0;
  int _preferencesRequest = 0;
  int _mutation = 0;
  int _accountEpoch = 0;
  bool _loadingMore = false;
  bool _refreshing = false;
  bool _loadMoreFailed = false;
  bool _initialFailed = false;
  bool _accountMismatch = false;
  Object? _loadMoreOperation;

  void _onScroll() {
    _reportVisiblePosts();
    if (_feedScroll.hasClients && _feedScroll.position.extentAfter < 600) {
      unawaited(_loadMorePosts());
    }
  }

  Future<void> _loadMorePosts() async {
    if (_loadingMore || _loadMoreFailed) return;
    final current = _feedData;
    if (current == null) return;
    final request = _feedRequest;
    final mutation = _mutation;
    final epoch = _accountEpoch;
    final cache = _moments;
    final ticket = cache?.currentRevision;
    final generation = _accountKey == null
        ? null
        : CacheRepository.momentsGeneration(_accountKey!);
    final cursor = current['next_cursor'] as String?;
    if (!mounted || cursor == null) return;
    final operation = _loadMoreOperation = Object();
    setState(() => _loadingMore = true);
    bool valid() =>
        mounted &&
        epoch == _accountEpoch &&
        request == _feedRequest &&
        mutation == _mutation &&
        (ticket == null || cache!.isCurrent(ticket));
    void display(Map<String, dynamic> next) {
      // Replace this page's cached projection on refresh (including removed
      // rows), retaining the preceding pages and their fresher duplicates.
      final merged = <String, dynamic>{};
      for (final item in [
        ...(current['items'] as List? ?? []),
        ...(next['items'] as List? ?? [])
      ]) {
        merged.putIfAbsent((item as Map)['id'].toString(), () => item);
      }
      setState(() => _feedData = {...next, 'items': merged.values.toList()});
    }

    var displayedCache = false;
    try {
      final cached = await cache?.loadPage(cursor);
      if (!valid() || !await _stillSameAccount() || !valid()) return;
      if (cached != null) {
        display(cached);
        displayedCache = true;
      }
      // A pending head refresh may reset the cursor chain. Local pages remain
      // usable meanwhile; defer competing network pagination until it settles.
      if (_refreshing) return;
      var next = await widget.api.momentsFeed(mode: 'latest', cursor: cursor);
      await _invalidationsReady;
      final sameAccount = await _stillSameAccount();
      if (!mounted ||
          !sameAccount ||
          epoch != _accountEpoch ||
          request != _feedRequest ||
          mutation != _mutation ||
          !valid()) {
        return;
      }
      next = cache?.project(next) ?? next;
      if (next['next_cursor'] == cursor) next = {...next, 'next_cursor': null};
      display(next);
      if (cache != null && ticket != null && generation != null) {
        await cache.savePage(cursor, next,
            ticket: ticket, expectedGeneration: generation);
        if (valid() && cache.persistenceError != null) {
          setState(() => _interactionError = '本地缓存保存失败，离线内容可能不完整');
        }
      }
    } catch (_) {
      if (mounted &&
          epoch == _accountEpoch &&
          request == _feedRequest &&
          mutation == _mutation) {
        setState(() {
          if (!displayedCache) {
            _loadMoreFailed = true;
          } else {
            _interactionError = '刷新失败，已保留本地动态';
          }
        });
      }
    } finally {
      if (mounted &&
          epoch == _accountEpoch &&
          identical(operation, _loadMoreOperation)) {
        setState(() => _loadingMore = false);
      }
    }
  }

  String? _coverUrl;
  String? _coverCacheKey;
  String? _interactionError;
  String? _identityError;
  ProfileRepository get _identityCache => widget.identityCache;

  void _commentDeleted() {
    final change = momentCommentDeletions.value;
    if (change == null ||
        !change.appliesTo(widget.api, _identityCache.profile?.username ?? '')) {
      return;
    }
    setState(() {
      _mutation++;
      final override = _itemOverrides[change.momentId];
      if (override != null) {
        _itemOverrides[change.momentId] = change.apply(override);
      }
      final data = _feedData;
      if (data != null) {
        _feedData = {
          ...data,
          'items': [
            for (final raw in data['items'] as List? ?? [])
              if (raw is Map && raw['id'] == change.momentId)
                {
                  ...raw,
                  'comments': [
                    for (final c in raw['comments'] as List? ?? [])
                      if (c is! Map || c['id'] != change.commentId) c
                  ]
                }
              else
                raw
          ]
        };
      }
    });
    final cache = _moments;
    if (cache != null) {
      unawaited(cache
          .mutateItem(change.momentId, deletedComment: change.commentId)
          .catchError((Object _) {}));
    }
  }

  @override
  void initState() {
    super.initState();
    momentCommentDeletions.addListener(_commentDeleted);
    _feedScroll.addListener(_onScroll);
    widget.unreadChanges?.addListener(_unreadChanged);
    _identityCache.addListener(_identityChanged);
    momentsPrivacyChanges.addListener(_privacyChanged);
    _startAccount();
  }

  void _startAccount() {
    ++_accountEpoch;
    ++_feedRequest;
    ++_preferencesRequest;
    _itemOverrides.clear();
    _pendingLikeIds.clear();
    _selectedComments.clear();
    _deletedIds.clear();
    _postKeys.clear();
    _feedData = null;
    _moments = null;
    _invalidationsReady = null;
    _accountKey = null;
    _viewerUserId = null;
    _coverUrl = null;
    _coverCacheKey = null;
    _interactionError = null;
    _identityError = null;
    _loadingMore = false;
    _refreshing = false;
    _loadMoreFailed = false;
    _initialFailed = false;
    _accountMismatch = false;
    _loadMoreOperation = null;
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
      await _identityCache.refresh();
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
      final url = value['cover_url']?.toString();
      // Keep an already visible cover if its renewed image cannot be fetched.
      if (mounted && _coverUrl != null && url != null && url != _coverUrl) {
        var failed = false;
        await precacheImage(
          MomentMediaCache.imageProvider(
            url,
            cacheKey: value['cover_cache_key']?.toString(),
            accountKey: _accountKey,
            trustedOrigin: widget.api.baseUri.origin,
          ),
          context,
          onError: (_, __) => failed = true,
        );
        if (failed) return;
      }
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

  void _privacyChanged() {
    if (!mounted) return;
    ++_feedRequest;
    ++_mutation;
    final epoch = ++_accountEpoch;
    setState(() {
      _feedData = null;
      _itemOverrides.clear();
      _selectedComments.clear();
      _pendingLikeIds.clear();
      _interactionError = null;
    });
    // clear invalidates memory synchronously and serializes its disk deletion
    // before later writes; a fresh authorized request need not wait for disk.
    final clearing = _moments?.clear();
    _invalidationsReady = null;
    if (clearing != null) unawaited(clearing.catchError((Object _) {}));
    if (epoch == _accountEpoch) unawaited(_refreshFeed());
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
        _accountMismatch = true;
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
    _invalidationsReady = _moments?.restoreInvalidations();
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
    final invalidationsReady = _invalidationsReady;
    setState(() {
      _refreshing = true;
      _initialFailed = false;
      _loadMoreOperation = null;
      _loadingMore = false;
    });
    try {
      var fresh = await widget.api.momentsFeed(mode: 'latest');
      await invalidationsReady;
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
      fresh = cache?.project(fresh) ?? fresh;
      if (cache != null) {
        unawaited(cache.saveHead(fresh).then((_) {
          if (mounted &&
              request == _feedRequest &&
              cache.persistenceError != null) {
            setState(() => _interactionError = '本地缓存保存失败，离线内容可能不完整');
          }
        }).catchError((Object _) {}));
      }
      setState(() {
        _feedData = fresh;
        _loadMoreFailed = false;
        _interactionError = null;
        _itemOverrides.removeWhere((id, _) => !_pendingLikeIds.contains(id));
      });
    } catch (_) {
      if (mounted && request == _feedRequest) {
        setState(() {
          _initialFailed = true;
          if (_feedData != null) _interactionError = '刷新失败，请重试';
        });
      }
    } finally {
      if (mounted && request == _feedRequest) {
        setState(() => _refreshing = false);
      }
    }
  }

  Future<void> _persistItem(
    MomentItem item,
    _ConfirmedMomentWrite write,
  ) async {
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
    if (cache != null) {
      unawaited(cache.mutateItem(item.id,
          deleted: write == _ConfirmedMomentWrite.deletion,
          fields: {
            if (write == _ConfirmedMomentWrite.likes) ...{
              'viewer_has_liked': item.liked,
              'like_count': item.likeCount,
              'like_users':
                  item.likeUsers.map((user) => user.toJson()).toList(),
            },
            if (write == _ConfirmedMomentWrite.comments)
              'comments':
                  item.comments.map((comment) => comment.toJson()).toList(),
          }).catchError((Object _) {}));
    }
    // Keep the displayed window while updating every persisted reference.
    final displayed = _feedData;
    if (mounted && displayed != null) {
      setState(() => _feedData = updated(displayed));
    }
  }

  @override
  void dispose() {
    momentsPrivacyChanges.removeListener(_privacyChanged);
    _feedScroll.dispose();
    widget.unreadChanges?.removeListener(_unreadChanged);
    _identityCache.removeListener(_identityChanged);
    momentCommentDeletions.removeListener(_commentDeleted);
    super.dispose();
  }

  Future<void> _toggleLike(MomentItem item) async {
    if (PendingMomentReaction.find(widget.api, item.id) != null) return;
    final epoch = _accountEpoch;
    final optimistic = _viewerUserId == null
        ? item.copyWith(
            liked: !item.liked,
            likeCount:
                (item.likeCount + (item.liked ? -1 : 1)).clamp(0, 1 << 30))
        : toggleMomentReaction(
            item, momentViewer(_identityCache, userId: _viewerUserId!));
    final pending = PendingMomentReaction.begin(widget.api, item.id);
    var succeeded = true;
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
      if (epoch == _accountEpoch && pending.audienceIsCurrent) {
        var current = _itemOverrides[item.id] ?? optimistic;
        if (_viewerUserId == null || _identityCache.profile == null) {
          try {
            final confirmed =
                MomentItem.fromJson(await widget.api.momentDetail(item.id));
            if (epoch != _accountEpoch || !pending.audienceIsCurrent) return;
            current = restoreMomentReaction(
                _itemOverrides[item.id] ?? current, confirmed);
            if (mounted) setState(() => _itemOverrides[item.id] = current);
          } catch (_) {/* Confirmed write; a later refresh fills identity. */}
        }
        await _persistItem(current, _ConfirmedMomentWrite.likes);
      }
    } catch (error) {
      succeeded = false;
      if (!mounted || epoch != _accountEpoch || !pending.audienceIsCurrent) {
        return;
      }
      setState(() {
        _itemOverrides[item.id] = restoreMomentReaction(
          _itemOverrides[item.id] ?? item,
          item,
        );
        _interactionError =
            error is BusinessApiException ? error.message : '点赞同步失败，请重试';
      });
    } finally {
      pending.finish(widget.api, succeeded ? optimistic : item);
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

  Future<void> _showComment(
    BuildContext context,
    MomentItem item, [
    MomentCommentView? comment,
    Rect? anchor,
  ]) {
    final epoch = _accountEpoch;
    return interactWithMomentComment(
      context,
      api: widget.api,
      momentId: item.id,
      currentUsername: _identityCache.profile?.username ?? '',
      identityCache: _identityCache,
      comment: comment,
      longPress: anchor != null,
      anchor: anchor,
      currentItem: () => epoch != _accountEpoch || _deletedIds.contains(item.id)
          ? null
          : _itemOverrides[item.id] ?? item,
      onChanged: (updated) => setState(() => _itemOverrides[item.id] = updated),
      onConfirmed: (updated) async {
        if (epoch == _accountEpoch) {
          await _persistItem(updated, _ConfirmedMomentWrite.comments);
        }
      },
      onSelectionChanged: (id) => setState(() {
        if (id == null) {
          _selectedComments.remove(item.id);
        } else {
          _selectedComments[item.id] = id;
        }
      }),
      onError: (message) => setState(() => _interactionError = message),
    );
  }

  Future<void> _openDetail(MomentItem item) async {
    final epoch = _accountEpoch;
    await Navigator.push(
      context,
      CupertinoPageRoute(
        builder: (_) => MomentDetailPage(
          contactActions: widget.contactActions,
          identityCache: _identityCache,
          viewerUserId: _viewerUserId,
          api: widget.api,
          initialItem: _itemOverrides[item.id] ?? item,
          currentUsername: _identityCache.profile?.username ?? '',
          cacheNamespace: _identityCache.accountKey ?? '',
          mediaAccountKey: _accountKey,
          mediaOrigin: widget.api.baseUri.origin,
          onConfirmed: (updated, change) async {
            if (!mounted || epoch != _accountEpoch) return;
            await _persistItem(
              updated,
              change == MomentDetailChange.comments
                  ? _ConfirmedMomentWrite.comments
                  : _ConfirmedMomentWrite.likes,
            );
          },
          onReactionChanged: (updated) {
            if (mounted && epoch == _accountEpoch) {
              setState(
                () => _itemOverrides[item.id] = restoreMomentReaction(
                  _itemOverrides[item.id] ?? item,
                  updated,
                ),
              );
            }
          },
          onChanged: (updated) {
            if (mounted && epoch == _accountEpoch) {
              setState(() => _itemOverrides[item.id] = updated);
            }
          },
        ),
      ),
    );
  }

  bool _openingAuthor = false;
  Future<void> _openAuthor(MomentAuthor author) async {
    if (_openingAuthor) return;
    _openingAuthor = true;
    try {
      await openMomentPerson(
        context,
        contactActions: widget.contactActions,
        api: widget.api,
        identityCache: _identityCache,
        person: author,
      );
      if (mounted) _reloadFeed();
    } catch (_) {
      if (mounted) setState(() => _interactionError = '资料加载失败，请重试');
    } finally {
      _openingAuthor = false;
    }
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
          backgroundColor: WeChatColors.navigationBackground(context),
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: const Text('朋友圈'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: () => Navigator.push(
                  context,
                  CupertinoPageRoute(
                    builder: (_) => MomentsSettingsPage(api: widget.api),
                  ),
                ),
                child: const Icon(CupertinoIcons.settings),
              ),
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
                child: const Icon(CupertinoIcons.camera),
              ),
            ],
          ),
        ),
        child: SafeArea(
          child: Builder(
            builder: (_) {
              final items = (_feedData?['items'] as List?) ?? const [];
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => _reportVisiblePosts(),
              );
              return CustomScrollView(
                controller: _feedScroll,
                // Build/load only the viewport plus half a screen on either
                // side. The shared media downloader bounds parallel requests.
                scrollCacheExtent: const ScrollCacheExtent.viewport(0.5),
                slivers: [
                  CupertinoSliverRefreshControl(onRefresh: _refreshFeed),
                  SliverList.list(children: [
                    if (_interactionError != null)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          _interactionError!,
                          key: const Key('moment-interaction-error'),
                          style:
                              const TextStyle(color: CupertinoColors.systemRed),
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
                                    trustedOrigin: widget.api.baseUri.origin,
                                  ),
                                  fit: BoxFit.cover,
                                  onError: (_, __) {},
                                ),
                        ),
                        alignment: Alignment.bottomRight,
                        padding: const EdgeInsets.all(16),
                        child: _ownerIdentity(),
                      ),
                    ),
                  ]),
                  SliverList.builder(
                    itemCount: items.length,
                    itemBuilder: (_, index) {
                      final m = items[index];
                      final parsed = MomentItem.fromJson(
                        Map<String, dynamic>.from(m as Map),
                      );
                      if (_deletedIds.contains(parsed.id)) {
                        return const SizedBox.shrink();
                      }
                      final item = _itemOverrides[parsed.id] ?? parsed;
                      return WeChatMomentTile(
                        key: _postKeys.putIfAbsent(item.id, GlobalKey.new),
                        identityCache: _identityCache,
                        item: visibleMomentReactions(item, _identityCache),
                        onAuthorTap: () => _openAuthor(item.author),
                        onPersonTap: _openAuthor,
                        selectedCommentId: _selectedComments[item.id],
                        cacheNamespace: _identityCache.accountKey ?? '',
                        onOpen: () => _openDetail(item),
                        onCommentLongPress: (comment, anchor) =>
                            _showComment(context, item, comment, anchor),
                        onCommentTap: (comment) =>
                            _showComment(context, item, comment),
                        mediaAccountKey: _accountKey,
                        mediaOrigin: widget.api.baseUri.origin,
                        onLike: _pendingLikeIds.contains(item.id)
                            ? null
                            : () => _toggleLike(item),
                        onComment: () => _showComment(context, item),
                        onDelete: _canDelete(item)
                            ? () => _confirmDelete(item)
                            : null,
                      );
                    },
                  ),
                  SliverToBoxAdapter(child: _paginationFooter(items)),
                ],
              );
            },
          ),
        ),
      );

  Widget _paginationFooter(List items) {
    if (_feedData == null) {
      if (_accountMismatch) {
        return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('账号已切换，请重新进入朋友圈')));
      }
      if (_initialFailed) {
        return CupertinoButton(
            key: const Key('moments-initial-retry'),
            onPressed: _reloadFeed,
            child: const Text('加载失败，点击重试'));
      }
      return const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CupertinoActivityIndicator()));
    }
    if (items.isEmpty) {
      return const Padding(
          key: Key('moments-empty'),
          padding: EdgeInsets.all(24),
          child: Center(child: Text('还没有朋友圈动态')));
    }
    if (_loadMoreFailed) {
      return CupertinoButton(
          key: const Key('moments-load-more-retry'),
          onPressed: () {
            setState(() => _loadMoreFailed = false);
            unawaited(_loadMorePosts());
          },
          child: const Text('加载失败，点击重试'));
    }
    if (_loadingMore) {
      return const Padding(
          key: Key('moments-footer-loading'),
          padding: EdgeInsets.all(16),
          child: Center(child: CupertinoActivityIndicator()));
    }
    if (_feedData?['next_cursor'] == null) {
      return const Padding(
          key: Key('moments-no-more'),
          padding: EdgeInsets.all(16),
          child: Center(child: Text('没有更多了')));
    }
    return CupertinoButton(
        key: const Key('moments-load-more'),
        onPressed: _loadMorePosts,
        child: const Text('加载更多'));
  }

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
            fallbackSeed: _identityCache
                .resolveIdentity(username: profile.username)
                .cacheKey,
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
    final image = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
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
      fileName: image.name,
      mimeType: mimeType,
      byteSize: bytes.length,
    );
    final uploadId = begun['id'].toString();
    await api.putMomentCoverUpload(uploadId, bytes, mimeType);
    await api.completeMomentCoverUpload(uploadId);
    final saved = await api.setMomentCover(uploadId);
    final coverUrl = saved['cover_url']?.toString();
    if (!await _stillSameAccount() || epoch != _accountEpoch) return null;
    ++_preferencesRequest;
    final cache = _moments;
    if (cache != null) {
      unawaited(
        cache.savePreferences({
          ...?cache.preferencesSnapshot,
          ...saved
        }).catchError((Object _) {}),
      );
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
