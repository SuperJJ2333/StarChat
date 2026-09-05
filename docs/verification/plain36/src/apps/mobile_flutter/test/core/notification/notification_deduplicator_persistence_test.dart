import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/notification_deduplicator.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 跨进程重启去重：系统推送已展示后，App 启动 + Matrix 同步不得再提醒
/// 一次（同一 eventId）。去重必须可持久化，且持久键为本地 opaque eventId。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('同一 store 的两个实例：第二个实例抑制同 eventId（跨重启语义）', () {
    final store = MemoryNotificationDedupStore();
    final first = NotificationDeduplicator(
      store: store,
      ttl: const Duration(hours: 24),
      now: () => DateTime.fromMillisecondsSinceEpoch(0),
    );
    expect(first.tryProcess('\$event-1'), isTrue);
    expect(first.tryProcess('\$event-1'), isFalse);

    final second = NotificationDeduplicator(
      store: store,
      ttl: const Duration(hours: 24),
      now: () => DateTime.fromMillisecondsSinceEpoch(0),
    );
    expect(second.tryProcess('\$event-1'), isFalse,
        reason: '重启后（新实例）同一事件不得二次提醒');
    expect(second.tryProcess('\$event-2'), isTrue);
  });

  test('TTL 过期后允许再次处理', () {
    var now = DateTime.fromMillisecondsSinceEpoch(0);
    final dedup = NotificationDeduplicator(
      store: MemoryNotificationDedupStore(),
      ttl: const Duration(minutes: 10),
      now: () => now,
    );
    expect(dedup.tryProcess('\$event-1'), isTrue);
    now = now.add(const Duration(minutes: 11));
    expect(dedup.tryProcess('\$event-1'), isTrue);
  });

  test('容量淘汰最旧条目（FIFO）', () {
    final dedup = NotificationDeduplicator(
      store: MemoryNotificationDedupStore(),
      ttl: const Duration(hours: 24),
      maxEntries: 2,
      now: () => DateTime.fromMillisecondsSinceEpoch(0),
    );
    dedup.tryProcess('\$e1');
    dedup.tryProcess('\$e2');
    dedup.tryProcess('\$e3');
    expect(dedup.hasProcessed('\$e1'), isFalse, reason: '最旧条目被淘汰');
    expect(dedup.hasProcessed('\$e2'), isTrue);
    expect(dedup.hasProcessed('\$e3'), isTrue);
  });

  test('SharedPreferences 持久层：create 时清理过期条目并保留有效条目', () async {
    final fresh = DateTime.now();
    final stale = fresh.subtract(const Duration(hours: 25)).toIso8601String();
    SharedPreferences.setMockInitialValues({
      SharedPreferencesNotificationDedupStore.prefsKey: jsonEncode({
        '\$stale-event': stale,
        '\$fresh-event': fresh.toIso8601String(),
      }),
    });
    final store = await SharedPreferencesNotificationDedupStore.create(
      ttl: const Duration(hours: 24),
    );
    expect(store.seenAt('\$stale-event'), isNull, reason: '过期条目在加载时清理');
    expect(store.seenAt('\$fresh-event'), isNotNull);

    // 写穿透：新标记的事件在重建实例后仍可读。
    store.markSeen('\$written-event', fresh);
    final restored = await SharedPreferencesNotificationDedupStore.create(
      ttl: const Duration(hours: 24),
    );
    expect(restored.seenAt('\$written-event'), isNotNull);
  });

  test('持久层内容只含 eventId→时间戳（无消息内容字段）', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await SharedPreferencesNotificationDedupStore.create();
    store.markSeen('\$opaque-event-id', DateTime.now());
    final prefs = await SharedPreferences.getInstance();
    final raw =
        prefs.getString(SharedPreferencesNotificationDedupStore.prefsKey);
    expect(raw, isNotNull);
    final decoded = jsonDecode(raw!) as Map<String, Object?>;
    expect(decoded.keys, everyElement(startsWith('\$')),
        reason: '键只能是 Matrix eventId（opaque）');
    for (final value in decoded.values) {
      expect(value is String, isTrue, reason: '值只能是 ISO 时间戳');
      expect(DateTime.tryParse(value as String), isNotNull);
    }
  });
}
