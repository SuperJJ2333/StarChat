import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';

void main() {
  DateTime utc(int y, int m, int d, [int h = 0, int min = 0]) =>
      DateTime.utc(y, m, d, h, min);

  test('formatLastSeenLabel 按时间档位动态展示', () {
    final now = utc(2026, 9, 12, 12);
    expect(formatLastSeenLabel(null, now: now), '暂无在线记录');
    expect(formatLastSeenLabel(now, now: now), '刚刚在线');
    expect(
        formatLastSeenLabel(now.subtract(const Duration(seconds: 30)),
            now: now),
        '刚刚在线');
    expect(
        formatLastSeenLabel(
            now.subtract(const Duration(minutes: 5)), now: now),
        '5分钟前在线');
    expect(
        formatLastSeenLabel(
            now.subtract(const Duration(hours: 3)), now: now),
        '3小时前在线');
    expect(
        formatLastSeenLabel(now.subtract(const Duration(days: 2)), now: now),
        '2天前在线');
    final eightDaysAgo = now.subtract(const Duration(days: 8));
    final local = eightDaysAgo.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    expect(
      formatLastSeenLabel(eightDaysAgo, now: now),
      '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)} 在线',
    );
  });

  test('ContactSummary 解析 last_seen_at；缺失时为 null', () {
    final withSeen = ContactSummary.fromJson({
      'user_id': 'u1',
      'username': 'alice',
      'matrix_user_id': '@a:t',
      'last_seen_at': '2026-09-12T04:00:00+00:00',
    });
    expect(withSeen.lastSeenAt, isNotNull);
    final without = ContactSummary.fromJson({
      'user_id': 'u2',
      'username': 'bob',
      'matrix_user_id': '@b:t',
      'last_seen_at': null,
    });
    expect(without.lastSeenAt, isNull);
    expect(without.toDetails().lastSeenAt, isNull);
  });
}
