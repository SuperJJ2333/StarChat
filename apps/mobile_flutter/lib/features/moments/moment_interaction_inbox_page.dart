import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../core/business_api_client.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/moments/moment_warning_banner.dart';
import '../../ui/motion/motion_page_route.dart';
import '../contacts/contact_actions.dart';
import '../matrix/profile_repository.dart';
import 'moment_detail_page.dart';
import 'moment_models.dart';

/// Authenticated, account-scoped history of likes, comments and replies.
/// A notification never grants access to its target Moment.
class MomentInteractionInboxPage extends StatefulWidget {
  const MomentInteractionInboxPage({
    super.key,
    required this.api,
    this.identityCache,
    this.contactActions,
    this.currentUsername = '',
    this.viewerUserId,
    this.mediaAccountKey,
    this.mediaOrigin,
    this.onNotificationsChanged,
  });

  final BusinessApiClient api;
  final ProfileRepository? identityCache;
  final ContactActions? contactActions;
  final String currentUsername;
  final String? viewerUserId, mediaAccountKey, mediaOrigin;
  final VoidCallback? onNotificationsChanged;

  @override
  State<MomentInteractionInboxPage> createState() =>
      _MomentInteractionInboxState();
}

class _MomentInteractionInboxState extends State<MomentInteractionInboxPage> {
  List<MomentNotificationItem> _items = const [];
  String? _nextCursor, _error, _accountId;
  int? _epoch;
  int _generation = 0;
  bool _loading = true, _loadingMore = false, _opening = false;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  @override
  void didUpdateWidget(covariant MomentInteractionInboxPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api || _epoch != widget.api.sessionEpoch) {
      unawaited(_reload());
    }
  }

  Future<bool> _scopeCurrent(BusinessApiClient api, int generation, int epoch,
      String accountId) async {
    if (!mounted || !identical(widget.api, api) || generation != _generation) {
      return false;
    }
    if (api.sessionEpoch != epoch) {
      unawaited(_reload());
      return false;
    }
    String? currentUserId;
    try {
      currentUserId = await api.currentUserId();
    } catch (_) {
      if (mounted &&
          generation == _generation &&
          identical(widget.api, api) &&
          api.sessionEpoch == epoch) {
        unawaited(_reload());
      }
      return false;
    }
    if (currentUserId != accountId) {
      if (mounted && generation == _generation) unawaited(_reload());
      return false;
    }
    return mounted && generation == _generation && api.sessionEpoch == epoch;
  }

  Future<void> _reload() async {
    final api = widget.api;
    final epoch = api.sessionEpoch;
    final generation = ++_generation;
    setState(() {
      _items = const [];
      _nextCursor = null;
      _error = null;
      _accountId = null;
      _epoch = epoch;
      _loading = true;
      _loadingMore = false;
    });
    try {
      final accountId = await api.currentUserId();
      if (!mounted ||
          generation != _generation ||
          api.sessionEpoch != epoch ||
          !identical(widget.api, api)) {
        return;
      }
      if (accountId == null || accountId.isEmpty) {
        setState(() {
          _loading = false;
          _error = '请重新登录后查看互动消息';
        });
        return;
      }
      _accountId = accountId;
      await _fetchPage(api, generation, epoch, accountId, null);
    } catch (_) {
      if (mounted && generation == _generation && api.sessionEpoch == epoch) {
        setState(() {
          _loading = false;
          _error = '互动消息加载失败，请重试';
        });
      }
    }
  }

  Future<void> _fetchPage(BusinessApiClient api, int generation, int epoch,
      String accountId, String? cursor) async {
    try {
      final response = await api.momentNotifications(cursor: cursor);
      if (!await _scopeCurrent(api, generation, epoch, accountId)) return;
      final incoming = (response['items'] as List? ?? const [])
          .map((value) => MomentNotificationItem.fromJson(
              Map<String, dynamic>.from(value as Map)))
          .toList(growable: false);
      final existing = {for (final item in _items) item.id: item};
      for (final item in incoming) {
        existing[item.id] = item;
      }
      setState(() {
        _items = existing.values.toList(growable: false);
        _nextCursor = response['next_cursor']?.toString();
        _error = null;
      });
      final unread = incoming
          .where((item) => item.readAt == null)
          .map((item) => item.id)
          .toList(growable: false);
      if (unread.isNotEmpty) {
        try {
          await api.markMomentNotificationsRead(unread);
          if (await _scopeCurrent(api, generation, epoch, accountId)) {
            widget.onNotificationsChanged?.call();
          }
        } catch (_) {
          // Keep the rows visible; the server remains the unread authority.
        }
      }
    } catch (_) {
      if (await _scopeCurrent(api, generation, epoch, accountId)) {
        setState(() => _error = '互动消息加载失败，请重试');
      }
    } finally {
      if (mounted && generation == _generation && api.sessionEpoch == epoch) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  Future<void> _loadMore() async {
    final cursor = _nextCursor;
    final accountId = _accountId;
    if (cursor == null || accountId == null || _loadingMore || _loading) return;
    setState(() => _loadingMore = true);
    await _fetchPage(widget.api, _generation, _epoch!, accountId, cursor);
  }

  Future<void> _showUnavailable() async {
    if (!mounted) return;
    await showCupertinoDialog<void>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: const Text('该内容不可查看'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _open(MomentNotificationItem notification) async {
    final accountId = _accountId;
    final epoch = _epoch;
    final api = widget.api;
    final generation = _generation;
    if (_opening ||
        accountId == null ||
        epoch == null ||
        !await _scopeCurrent(api, generation, epoch, accountId)) {
      return;
    }
    setState(() => _opening = true);
    try {
      // The notification is historical metadata. Never render a cached post
      // before this live, authorized detail request succeeds.
      final response = await api.momentDetail(notification.momentId);
      if (!await _scopeCurrent(api, generation, epoch, accountId)) return;
      final item = MomentItem.fromJson(response);
      if (item.id != notification.momentId || item.status != 'PUBLISHED') {
        await _showUnavailable();
        return;
      }
      final comment = item.comments
          .where((value) => value.id == notification.commentId)
          .firstOrNull;
      if (!mounted) return;
      await Navigator.push(
        context,
        MotionPageRoute(
          builder: (_) => MomentDetailPage(
            api: api,
            identityCache: widget.identityCache,
            contactActions: widget.contactActions,
            initialItem: item,
            currentUsername: widget.currentUsername,
            viewerUserId: widget.viewerUserId,
            mediaAccountKey: widget.mediaAccountKey,
            mediaOrigin: widget.mediaOrigin,
            highlightCommentId: comment?.id,
            cacheNamespace: 'notification:${notification.momentId}',
          ),
        ),
      );
    } on BusinessApiException catch (failure) {
      if (await _scopeCurrent(api, generation, epoch, accountId)) {
        if ([401, 403, 404].contains(failure.statusCode)) {
          await _showUnavailable();
        } else {
          setState(() => _error = '内容加载失败，请重试');
        }
      }
    } catch (_) {
      if (await _scopeCurrent(api, generation, epoch, accountId)) {
        setState(() => _error = '内容加载失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  String _action(MomentNotificationItem item) {
    return switch (item.kind) {
      'LIKE' => '赞了你的朋友圈',
      'COMMENT' => '评论了你的朋友圈',
      'REPLY' => '回复了你的评论',
      _ => '与你互动',
    };
  }

  Widget _row(MomentNotificationItem item) {
    final available = item.targetAvailable;
    final headline = available && item.actor != null
        ? '${item.actor!.displayName} ${_action(item)}'
        : switch (item.kind) {
            'COMMENT' => '朋友圈评论提醒',
            'REPLY' => '朋友圈回复提醒',
            'LIKE' => '朋友圈点赞提醒',
            _ => '互动提醒',
          };
    return CupertinoButton(
      key: Key('moment-notification-${item.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      onPressed: _opening ? null : () => _open(item),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(headline,
                style: const TextStyle(
                    fontSize: 16, color: CupertinoColors.label)),
          ),
          Text(formatMomentTime(item.createdAt),
              style: const TextStyle(
                  fontSize: 12, color: CupertinoColors.secondaryLabel)),
        ]),
        const SizedBox(height: 6),
        Text(available ? (item.contentExcerpt ?? '') : '该内容不可查看',
            style: const TextStyle(
                fontSize: 14, color: CupertinoColors.secondaryLabel)),
        if (available && item.sourceExcerpt != null) ...[
          const SizedBox(height: 4),
          Text(item.sourceExcerpt!,
              style: const TextStyle(
                  fontSize: 13, color: CupertinoColors.tertiaryLabel)),
        ],
        const SizedBox(height: 10),
        Container(height: 0.5, color: CupertinoColors.separator),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_epoch != null && _epoch != widget.api.sessionEpoch) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _epoch != widget.api.sessionEpoch) unawaited(_reload());
      });
    }
    final scopedItems = _epoch == widget.api.sessionEpoch
        ? _items
        : const <MomentNotificationItem>[];
    return WeChatPageScaffold.navigation(
      navigationBar: const CupertinoNavigationBar(middle: Text('全部互动消息')),
      child: SafeArea(
        child: ListView(children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(children: [
                MomentWarningBanner(message: _error!),
                CupertinoButton(onPressed: _reload, child: const Text('重试')),
              ]),
            ),
          if (_loading && scopedItems.isEmpty)
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CupertinoActivityIndicator()),
            ),
          if (!_loading && scopedItems.isEmpty && _error == null)
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: Text('暂无互动消息')),
            ),
          for (final item in scopedItems) _row(item),
          if (_nextCursor != null && scopedItems.isNotEmpty)
            CupertinoButton(
              key: const Key('moment-notifications-more'),
              onPressed: _loadingMore ? null : _loadMore,
              child: _loadingMore
                  ? const CupertinoActivityIndicator()
                  : const Text('加载更多'),
            ),
        ]),
      ),
    );
  }
}
