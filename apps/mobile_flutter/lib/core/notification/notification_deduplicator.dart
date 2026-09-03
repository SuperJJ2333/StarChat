/// 事件去重缓存（PRD §25/§66）。
///
/// Matrix WebSocket 与推送可能交付同一 event_id；TTL 内的第二 arrival
/// 直接丢弃，保证声音、震动、通知、角标各只执行一次。
final class NotificationDeduplicator {
  NotificationDeduplicator({
    this.ttl = const Duration(minutes: 10),
    this.maxEntries = 512,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  final Duration ttl;
  final int maxEntries;
  final DateTime Function() now;

  /// Dart Map 保持插入顺序，用于容量淘汰最旧条目。
  final Map<String, DateTime> _processed = {};

  /// 是否已处理过（仍在 TTL 内）。
  bool hasProcessed(String eventId) {
    final at = _processed[eventId];
    if (at == null) return false;
    if (now().difference(at) >= ttl) {
      _processed.remove(eventId);
      return false;
    }
    return true;
  }

  /// 尝试占用事件；重复事件返回 false。
  bool tryProcess(String eventId) {
    if (hasProcessed(eventId)) return false;
    _processed[eventId] = now();
    while (_processed.length > maxEntries) {
      _processed.remove(_processed.keys.first);
    }
    return true;
  }
}
