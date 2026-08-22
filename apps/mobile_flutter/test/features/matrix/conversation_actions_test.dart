import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_preferences.dart';

void main() {
  test('manual unread clears when a room is opened', () {
    const preference = ConversationPreference(manualUnread: true);
    expect(clearUnreadOnOpen(preference).manualUnread, isFalse);
  });

  test('newer incoming event restores a hidden conversation', () {
    final hidden = ConversationPreference(
      hidden: true,
      hiddenAt: DateTime.utc(2026, 8, 21, 10),
    );
    expect(
      restoreForIncomingEvent(
        hidden,
        eventAt: DateTime.utc(2026, 8, 21, 10, 1),
        isIncoming: true,
      ).hidden,
      isFalse,
    );
    expect(
      restoreForIncomingEvent(
        hidden,
        eventAt: DateTime.utc(2026, 8, 21, 10, 1),
        isIncoming: false,
      ).hidden,
      isTrue,
    );
  });
}
