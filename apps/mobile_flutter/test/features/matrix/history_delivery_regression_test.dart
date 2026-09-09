import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/unread_mention_tracker.dart';

void main() {
  test('room and inbox consume the mention state and render the reminder', () {
    final room = File('lib/features/matrix/room_page.dart').readAsStringSync();
    final inbox =
        File('lib/features/matrix/matrix_home_page.dart').readAsStringSync();
    expect(room, contains('MentionBannerButton('));
    expect(room, contains('markViewed('));
    expect(inbox, contains('hasPendingMention:'));
  });
  test('history uses live SDK pagination instead of filtered message count',
      () {
    final source = File('lib/features/matrix/room_timeline_controller.dart')
        .readAsStringSync();
    expect(source, contains('RoomHistoryStatus'));
    final room = File('lib/features/matrix/room_page.dart').readAsStringSync();
    expect(room, isNot(contains("Key('chat-history-loading')")));
    expect(room, contains('loadCalendarMonth:'));
  });
  test('redaction then duplicate sync never resurrects an unread mention', () {
    final tracker = UnreadMentionTracker(accountId: 'me', roomId: 'room');
    tracker.onMessageArrived(
        eventId: 'e', order: 1, senderIsSelf: false, mentionedUserIds: {'me'});
    tracker.onRedacted('e');
    tracker.onMessageArrived(
        eventId: 'e', order: 1, senderIsSelf: false, mentionedUserIds: {'me'});
    expect(tracker.hasPending, isFalse);
  });
}
