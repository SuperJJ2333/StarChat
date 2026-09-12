import 'dart:async';

import 'package:flutter/scheduler.dart';

import '../../core/business_api_client.dart';

/// 好友资料页朋友圈预览的会话作用域缓存。
///
/// 每个 API 客户端及其登录 epoch 都有独立的缓存。Expando 不会让已经
/// 释放的 API 所有者常驻；cache 本身也只弱引用 API。这样账号切换后的
/// 迟到请求不能将旧账号的授权结果发布给新会话。
final class MomentPreviewCache {
  MomentPreviewCache._(BusinessApiClient api, this.ttl)
      : _api = WeakReference(api),
        _epoch = api.sessionEpoch;

  static final Expando<MomentPreviewCache> _byApi =
      Expando<MomentPreviewCache>('moment-preview-cache');

  factory MomentPreviewCache.forApi(BusinessApiClient api,
      {Duration ttl = const Duration(minutes: 5)}) {
    final existing = _byApi[api];
    if (existing != null && existing._isCurrentFor(api)) return existing;
    existing?._retire();
    final created = MomentPreviewCache._(api, ttl);
    _byApi[api] = created;
    return created;
  }

  final Duration ttl;
  final WeakReference<BusinessApiClient> _api;
  final int _epoch;
  var _retired = false;

  final _entries = <String, _PreviewEntry>{};
  final _listeners = <String, Set<VoidCallback>>{};
  final _inFlight = <String, Future<void>>{};
  final _revisions = <String, int>{};
  final _queuedNotifications = <String>{};

  bool get _isCurrent {
    final api = _api.target;
    return !_retired && api != null && api.sessionEpoch == _epoch;
  }

  bool _isCurrentFor(BusinessApiClient api) =>
      _isCurrent && identical(_api.target, api);

  void _retire() {
    _retired = true;
    _entries.clear();
    _inFlight.clear();
    _revisions.clear();
    _queuedNotifications.clear();
    _listeners.clear();
  }

  /// 进页同步读取缓存（可能为 null：首次且预取未完成）。
  Map<String, dynamic>? peek(String userId) =>
      _isCurrent ? _entries[userId]?.payload : null;

  void addListener(String userId, VoidCallback listener) {
    if (!_isCurrent) return;
    _listeners.putIfAbsent(userId, () => <VoidCallback>{}).add(listener);
  }

  void removeListener(String userId, VoidCallback listener) {
    _listeners[userId]?.remove(listener);
    if (_listeners[userId]?.isEmpty ?? false) _listeners.remove(userId);
  }

  void _notify(String userId) {
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      _dispatchListeners(userId);
      return;
    }
    if (!_queuedNotifications.add(userId)) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _queuedNotifications.remove(userId);
      _dispatchListeners(userId);
    });
  }

  void _dispatchListeners(String userId) {
    // A listener can remove itself while handling the update, so use a stable
    // snapshot instead of iterating the mutable per-user set.
    final listeners = List<VoidCallback>.of(
        _listeners[userId] ?? const <VoidCallback>[]);
    for (final listener in listeners) {
      listener();
    }
  }

  /// 首次、过期或明确失效后静默刷新；同一作用域同一用户只保留一个请求。
  void ensureFresh(String userId) {
    final api = _api.target;
    if (!_isCurrent || api == null) return;
    final entry = _entries[userId];
    if (entry != null && DateTime.now().difference(entry.fetchedAt) < ttl) {
      return;
    }
    if (_inFlight.containsKey(userId)) return;
    final revision = _revisions[userId] ?? 0;
    late final Future<void> request;
    request = api.momentProfilePreview(userId).then((fresh) {
      if (!_isCurrent || (_revisions[userId] ?? 0) != revision) {
        return;
      }
      final old = _entries[userId];
      if (old != null && _samePayload(old.payload, fresh)) {
        old.fetchedAt = DateTime.now();
        return;
      }
      _entries[userId] = _PreviewEntry(fresh, DateTime.now());
      _notify(userId);
    }).onError((Object error, StackTrace stackTrace) {
      if (_isCurrent &&
          (_revisions[userId] ?? 0) == revision &&
          error is BusinessApiException &&
          (error.statusCode == 403 || error.statusCode == 404)) {
        _entries.remove(userId);
        _notify(userId);
      }
      // Transient failures retain same-scope cached UI but do not publish any
      // value to a different API/epoch scope.
    }).whenComplete(() {
      if (identical(_inFlight[userId], request)) _inFlight.remove(userId);
    });
    _inFlight[userId] = request;
  }

  Future<void> prefetch(Iterable<String> userIds, {int concurrency = 3}) async {
    final pending = userIds.toList(growable: false);
    var next = 0;
    final workers = List.generate(
        concurrency,
        (_) => Future.doWhile(() async {
              if (!_isCurrent || next >= pending.length) return false;
              final userId = pending[next++];
              ensureFresh(userId);
              await _inFlight[userId];
              return true;
            }));
    await Future.wait(workers);
  }

  /// 权限变化先隐藏旧授权；已开始的请求由 revision 围栏拒绝。
  void invalidate(String userId) {
    _revisions[userId] = (_revisions[userId] ?? 0) + 1;
    _entries.remove(userId);
    _inFlight.remove(userId);
    _notify(userId);
  }

  bool _samePayload(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a['entry_visible'] != b['entry_visible']) return false;
    final itemsA = (a['items'] as List? ?? const []).length;
    final itemsB = (b['items'] as List? ?? const []).length;
    if (itemsA != itemsB) return false;
    return (a['items'] as List? ?? const []).toString() ==
        (b['items'] as List? ?? const []).toString();
  }
}

final class _PreviewEntry {
  _PreviewEntry(this.payload, this.fetchedAt);
  final Map<String, dynamic> payload;
  DateTime fetchedAt;
}
