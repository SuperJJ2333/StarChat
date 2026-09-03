import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/notification_deduplicator.dart';

void main() {
  group('PRD §25/§66 事件去重', () {
    test('同一 eventId 只处理一次', () {
      final dedup = NotificationDeduplicator();
      expect(dedup.tryProcess(r'$ev1'), isTrue);
      expect(dedup.tryProcess(r'$ev1'), isFalse);
      expect(dedup.tryProcess(r'$ev2'), isTrue);
    });

    test('TTL 过期后同一 eventId 可再次处理', () {
      var clock = DateTime(2026, 9, 3, 12);
      final dedup = NotificationDeduplicator(
        ttl: const Duration(minutes: 10),
        now: () => clock,
      );
      expect(dedup.tryProcess(r'$ev1'), isTrue);
      clock = clock.add(const Duration(minutes: 10, seconds: 1));
      expect(dedup.tryProcess(r'$ev1'), isTrue);
    });

    test('TTL 内重复事件被丢弃（Matrix + Push 双通道只响一次）', () {
      var clock = DateTime(2026, 9, 3, 12);
      final dedup = NotificationDeduplicator(
        ttl: const Duration(minutes: 10),
        now: () => clock,
      );
      expect(dedup.tryProcess(r'$ev1'), isTrue);
      clock = clock.add(const Duration(seconds: 3));
      expect(dedup.tryProcess(r'$ev1'), isFalse);
    });

    test('容量上限触发最旧条目淘汰，不无限增长', () {
      var clock = DateTime(2026, 9, 3, 12);
      final dedup = NotificationDeduplicator(
        ttl: const Duration(hours: 1),
        maxEntries: 2,
        now: () => clock,
      );
      expect(dedup.tryProcess(r'$ev1'), isTrue);
      expect(dedup.tryProcess(r'$ev2'), isTrue);
      expect(dedup.tryProcess(r'$ev3'), isTrue); // $ev1 被淘汰。
      expect(dedup.tryProcess(r'$ev1'), isTrue); // 淘汰后可再次占用。
      expect(dedup.tryProcess(r'$ev3'), isFalse); // $ev3 仍在缓存且未过期。
    });

    test('hasProcess 只查询不记录', () {
      final dedup = NotificationDeduplicator();
      expect(dedup.hasProcessed(r'$ev1'), isFalse);
      expect(dedup.tryProcess(r'$ev1'), isTrue);
      expect(dedup.hasProcessed(r'$ev1'), isTrue);
      expect(dedup.tryProcess(r'$ev1'), isFalse);
    });
  });
}
