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
    expect(room, isNot(contains('loadedDayMetadata')),
        reason: 'calendar day metadata comes from RoomHistoryDayIndex, not the '
            'timeline projection');
    expect(room, contains('loadCalendarMonth:'),
        reason: 'the calendar reads bounded month metadata');
    expect(room, contains('load.loadMonthDays(month)'),
        reason: 'month metadata must go through the date capability');
    expect(room, isNot(contains('DateTime(1970')),
        reason: 'an unknown earliest month must never be faked as 1970');
    expect(room, contains('final token = widget.roomLease.historyToken;'),
        reason: 'the independent text-search pagination contract remains');
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
