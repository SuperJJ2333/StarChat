import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/badge_service.dart';
import 'package:liuhetong_mobile/core/notification/notification_preferences.dart';

void main() {
  group('PRD §35/§36 桌面角标聚合', () {
    test('角标等于所有未读会话的真实未读总数', () {
      const prefs = NotificationPreferenceValues();
      final total = aggregateLauncherBadge(
        prefs: prefs,
        conversations: const [
          ConversationUnreadSnapshot(roomId: '!a', unread: 2, isMuted: false),
          ConversationUnreadSnapshot(roomId: '!b', unread: 5, isMuted: false),
        ],
      );
      expect(total, 7);
    });

    test('静音会话默认计入角标，可由设置排除', () {
      const conversations = [
        ConversationUnreadSnapshot(roomId: '!a', unread: 2, isMuted: false),
        ConversationUnreadSnapshot(roomId: '!m', unread: 5, isMuted: true),
      ];
      expect(
        aggregateLauncherBadge(
          prefs: const NotificationPreferenceValues(),
          conversations: conversations,
        ),
        7,
      );
      expect(
        aggregateLauncherBadge(
          prefs: const NotificationPreferenceValues(
            mutedConversationsInBadge: false,
          ),
          conversations: conversations,
        ),
        2,
      );
    });

    test('手动标记未读不计入桌面角标（非真实未读）', () {
      const prefs = NotificationPreferenceValues();
      final total = aggregateLauncherBadge(
        prefs: prefs,
        conversations: const [
          ConversationUnreadSnapshot(
            roomId: '!a',
            unread: 0,
            isMuted: false,
            manualUnread: true,
          ),
          ConversationUnreadSnapshot(roomId: '!b', unread: 3, isMuted: false),
        ],
      );
      expect(total, 3);
    });

    test('未读为 0 或负数的会话不参与求和', () {
      const prefs = NotificationPreferenceValues();
      final total = aggregateLauncherBadge(
        prefs: prefs,
        conversations: const [
          ConversationUnreadSnapshot(roomId: '!a', unread: 0, isMuted: false),
          ConversationUnreadSnapshot(roomId: '!b', unread: -1, isMuted: false),
          ConversationUnreadSnapshot(roomId: '!c', unread: 4, isMuted: false),
        ],
      );
      expect(total, 4);
    });
  });
}
