import 'dart:async';

import 'package:flutter/foundation.dart';

/// 好友资料页朋友圈预览 / 在线状态的共享缓存（规格：无感加载）。
///
/// - 冷启动后台预取：App 启动后为好友列表预取预览数据，进页直接渲染
///   缓存，不发起请求；
/// - 后台刷新：仅在缓存过期（默认 5 分钟）时于后台拉取最新数据，
///   与缓存**逐字段比对**，有变化才通知 UI——避免每次进页都闪烁/刷新；
/// - 进页永不阻塞：读取缓存是同步的，刷新永远在后台。
final class MomentPreviewCache {
  MomentPreviewCache({this.ttl = const Duration(minutes: 5)});

  /// 缓存有效期：期内进页完全不发请求；过期后进页先显示缓存，
  /// 后台静默刷新，有更新才重建 UI。
  final Duration ttl;

  final _entries = <String, _PreviewEntry>{};
  final _listeners = <String, Set<VoidCallback>>{};
  final _inFlight = <String, Future<Map<String, dynamic>?>>{};

  /// 数据源：服务端预览接口。
  Future<Map<String, dynamic>?> Function(String userId)? fetcher;

  static final MomentPreviewCache instance = MomentPreviewCache();

  /// 进页同步读取缓存（可能为 null：首次且预取未完成）。
  Map<String, dynamic>? peek(String userId) =>
      _entries[userId]?.payload;

  /// 注册数据变化监听（进页时挂上，离页自动移除）。
  void addListener(String userId, VoidCallback listener) {
    _listeners.putIfAbsent(userId, () => <VoidCallback>{}).add(listener);
  }

  void removeListener(String userId, VoidCallback listener) {
    _listeners[userId]?.remove(listener);
    if (_listeners[userId]?.isEmpty ?? false) _listeners.remove(userId);
  }

  void _notify(String userId) {
    for (final listener in _listeners[userId] ?? const <VoidCallback>[]) {
      listener();
    }
  }

  /// 冷启动/进页触发：缓存新鲜则什么都不做；过期或缺失才后台刷新。
  void ensureFresh(String userId) {
    final fetch = fetcher;
    if (fetch == null) return;
    final entry = _entries[userId];
    final now = DateTime.now();
    if (entry != null && now.difference(entry.fetchedAt) < ttl) return;
    if (_inFlight.containsKey(userId)) return;
    final future = fetch(userId).then((fresh) {
      _inFlight.remove(userId);
      if (fresh == null) return null;
      final old = _entries[userId];
      // 有更新才写入并通知：内容无变化（entry_visible/items 相同）
      // 不触发 UI 重建，实现“有更新才刷新”。
      if (old != null && _samePayload(old.payload, fresh)) {
        old.fetchedAt = now; // 只续期时间戳。
        return fresh;
      }
      _entries[userId] = _PreviewEntry(fresh, now);
      _notify(userId);
      return fresh;
    }).catchError((_) {
      _inFlight.remove(userId);
      return null;
    });
    _inFlight[userId] = future;
  }

  /// 冷启动后台预取好友列表的全部预览（并发受限）。
  Future<void> prefetch(Iterable<String> userIds, {int concurrency = 3}) async {
    final pending = userIds.toList(growable: false);
    final workers = List.generate(
        concurrency,
        (_) => Future.doWhile(() async {
              if (pending.isEmpty) return false;
              final userId = pending.removeAt(0);
              ensureFresh(userId);
              await _inFlight[userId];
              return true;
            }));
    await Future.wait(workers);
  }

  /// 测试支持：清空全部缓存与数据源。
  @visibleForTesting
  void resetForTest() {
    _entries.clear();
    _listeners.clear();
    _inFlight.clear();
    fetcher = null;
  }

  /// 朋友圈发布/删除后主动失效（下次进页后台刷新一次）。
  void invalidate(String userId) {
    _entries.remove(userId);
    _notify(userId);
  }

  /// 逐字段比对：预览可见性与条目列表一致视为无更新。
  bool _samePayload(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a['entry_visible'] != b['entry_visible']) return false;
    final itemsA = (a['items'] as List? ?? const []).length;
    final itemsB = (b['items'] as List? ?? const []).length;
    if (itemsA != itemsB) return false;
    // 深比对：直接比对 JSON 序列化结果（条目数少，代价可忽略）。
    final keysA = (a['items'] as List? ?? const []).toString();
    final keysB = (b['items'] as List? ?? const []).toString();
    return keysA == keysB;
  }
}

final class _PreviewEntry {
  _PreviewEntry(this.payload, this.fetchedAt);
  Map<String, dynamic> payload;
  DateTime fetchedAt;
}
