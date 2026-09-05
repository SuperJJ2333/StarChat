import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_preferences.dart';

void main() {
  test('pinned groups keep their original pin order despite new activity', () {
    final first = ConversationProjection(
      roomId: '!first:test',
      isGroup: true,
      lastActivity: DateTime.utc(2026, 8, 18, 12),
      preference: ConversationPreference(
        pinned: true,
        pinnedAt: DateTime.utc(2026, 8, 18, 8),
      ),
    );
    final second = ConversationProjection(
      roomId: '!second:test',
      isGroup: true,
      lastActivity: DateTime.utc(2026, 8, 18, 10),
      preference: ConversationPreference(
        pinned: true,
        pinnedAt: DateTime.utc(2026, 8, 18, 9),
      ),
    );

    expect(orderConversations([second, first]), [first, second]);
  });

  test('ordinary conversations use descending activity order', () {
    final old = ConversationProjection(
      roomId: '!old:test',
      isGroup: false,
      lastActivity: DateTime.utc(2026, 8, 17),
    );
    final latest = ConversationProjection(
      roomId: '!latest:test',
      isGroup: false,
      lastActivity: DateTime.utc(2026, 8, 18),
    );
    expect(orderConversations([old, latest]), [latest, old]);
  });

  test('preference codec preserves notification exceptions and pin time', () {
    final preference = ConversationPreference.fromContent({
      'pinned': true,
      'pinned_at': '2026-08-18T08:00:00.000Z',
      'muted': true,
      'folded': true,
      'notify_mention_me': true,
      'notify_mention_all': false,
      'notify_announcement': true,
      'followed_member_ids': ['@a:test', '@b:test'],
    });
    expect(preference.pinnedAt, DateTime.utc(2026, 8, 18, 8));
    expect(preference.folded, isTrue);
    expect(preference.followedMemberIds, ['@a:test', '@b:test']);
    expect(preference.toContent()['notify_mention_all'], isFalse);
  });

  test('member order removes leavers and appends new or rejoined members', () {
    expect(
      reconcileMemberOrder(
        const ['@a:test', '@b:test', '@c:test'],
        const ['@a:test', '@c:test', '@d:test'],
      ),
      const ['@a:test', '@c:test', '@d:test'],
    );
    expect(
      reconcileMemberOrder(
        const ['@a:test', '@c:test', '@d:test'],
        const ['@a:test', '@b:test', '@c:test', '@d:test'],
      ),
      const ['@a:test', '@c:test', '@d:test', '@b:test'],
    );
  });
}
