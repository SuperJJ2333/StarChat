import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/chat_history_search.dart';

void main() {
  test('groups local chat results by newest calendar day', () {
    final grouped = groupChatSearchByDate([
      LocalChatSearchEntry(
        eventId: 'one',
        senderId: 'alice',
        timestamp: DateTime(2026, 8, 20, 10),
        text: '早上好',
      ),
      LocalChatSearchEntry(
        eventId: 'two',
        senderId: 'bob',
        timestamp: DateTime(2026, 8, 21, 9),
        text: '下午好',
      ),
    ]);

    expect(grouped.keys.first, DateTime(2026, 8, 21));
    expect(grouped[DateTime(2026, 8, 20)]!.single.eventId, 'one');
  });
}
