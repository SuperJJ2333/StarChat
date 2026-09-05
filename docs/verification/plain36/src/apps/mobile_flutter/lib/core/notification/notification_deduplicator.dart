import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 事件去重存储抽象（PRD §25/§66）：
/// - 内存实现：会话内 onSync 重复投递去重；
/// - 持久化实现：跨进程重启去重——系统推送已展示的事件，App 冷启动后
///   Matrix 同步到达同一 eventId 时不得二次提醒。
abstract interface class NotificationDedupStore {
  DateTime? seenAt(String eventId);

  void markSeen(String eventId, DateTime at);

  void forget(String eventId);

  /// 插入序 eventId（用于 FIFO 容量淘汰）。
  Iterable<String> eventIds();
}

final class MemoryNotificationDedupStore implements NotificationDedupStore {
  final Map<String, DateTime> _at = {};

  @override
  DateTime? seenAt(String eventId) => _at[eventId];

  @override
  void markSeen(String eventId, DateTime at) => _at[eventId] = at;

  @override
  void forget(String eventId) => _at.remove(eventId);

  @override
  Iterable<String> eventIds() => _at.keys;
}

/// SharedPreferences 持久化去重。
///
/// 持久键为 Matrix eventId（本地 opaque 标识）→ ISO 时间戳；不含消息
/// 正文、房间名或任何明文（apps/mobile_flutter/AGENTS.md）。创建时清理
/// 过期条目。注意：默认实例使用前需 `SharedPreferences.getInstance()`
/// 就绪（Flutter 侧通常已初始化）。
final class SharedPreferencesNotificationDedupStore
    implements NotificationDedupStore {
  SharedPreferencesNotificationDedupStore._(this._at);

  static const prefsKey = 'notification.dedup.v1';

  /// 默认保留窗口与推送点击后冷启动同步的时间尺度匹配（用户可能数
  /// 小时后才点开推送；陈旧事件另有 5 分钟 stale window 防历史轰炸）。
  static const defaultTtl = Duration(hours: 24);

  final Map<String, DateTime> _at;

  static Future<SharedPreferencesNotificationDedupStore> create({
    Duration ttl = defaultTtl,
    DateTime Function()? now,
  }) async {
    final clock = now ?? DateTime.now;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(prefsKey);
    final map = <String, DateTime>{};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            if (key is! String) return;
            final at = DateTime.tryParse(value.toString());
            if (at == null) return;
            if (clock().difference(at) >= ttl) return;
            map[key] = at;
          });
        }
      } catch (_) {
        // 损坏则从空开始。
      }
    }
    return SharedPreferencesNotificationDedupStore._(map);
  }

  @override
  DateTime? seenAt(String eventId) => _at[eventId];

  @override
  void markSeen(String eventId, DateTime at) {
    _at[eventId] = at;
    _persist();
  }

  @override
  void forget(String eventId) {
    if (_at.remove(eventId) != null) _persist();
  }

  @override
  Iterable<String> eventIds() => _at.keys;

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        prefsKey,
        jsonEncode({
          for (final entry in _at.entries)
            entry.key: entry.value.toIso8601String(),
        }),
      );
    } catch (_) {
      // 持久化失败退化为会话内去重，不影响主流程。
    }
  }
}

/// 事件去重缓存（PRD §25/§66）。
///
/// Matrix WebSocket 与推送可能交付同一 event_id；TTL 内的第二 arrival
/// 直接丢弃，保证声音、震动、通知、角标各只执行一次。默认内存实现；
/// 注入持久 store 可获得跨进程重启去重能力。
final class NotificationDeduplicator {
  NotificationDeduplicator({
    NotificationDedupStore? store,
    this.ttl = const Duration(minutes: 10),
    this.maxEntries = 512,
    DateTime Function()? now,
  })  : store = store ?? MemoryNotificationDedupStore(),
        now = now ?? DateTime.now;

  final NotificationDedupStore store;
  final Duration ttl;
  final int maxEntries;
  final DateTime Function() now;

  /// 是否已处理过（仍在 TTL 内）。
  bool hasProcessed(String eventId) {
    final at = store.seenAt(eventId);
    if (at == null) return false;
    if (now().difference(at) >= ttl) {
      store.forget(eventId);
      return false;
    }
    return true;
  }

  /// 尝试占用事件；重复事件返回 false。
  bool tryProcess(String eventId) {
    if (hasProcessed(eventId)) return false;
    store.markSeen(eventId, now());
    final ids = store.eventIds().toList();
    while (ids.length > maxEntries) {
      store.forget(ids.removeAt(0));
    }
    return true;
  }
}
