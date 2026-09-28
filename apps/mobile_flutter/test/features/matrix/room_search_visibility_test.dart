import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';
import 'package:liuhetong_mobile/features/matrix/room_search_visibility.dart';

ChatSearchMessage row({
  bool displayable = true,
  bool flash = false,
  String text = 'new edited text',
  ChatSearchMediaCategory? media,
}) =>
    ChatSearchMessage(
      eventId: 'old-event',
      senderId: '@synthetic:local',
      senderDisplayName: 'Synthetic',
      timestamp: DateTime.utc(2026, 9, 28),
      timelineOrder: 1,
      visibleText: text,
      isDisplayable: displayable,
      isFlashPhoto: flash,
      mediaCategory: media,
    );

void main() {
  test('retained source hidden state controls search visibility', () {
    final scanned = row();
    final checked = <String>[];
    ChatSearchMessage? project(String source) => visibleLocalSearchRow(
          sourceRoomId: source,
          row: scanned,
          isHidden: (roomId, eventId, timestamp) {
            checked.add(roomId);
            expect(eventId, 'old-event');
            expect(timestamp, scanned.timestamp);
            return roomId == 'retained';
          },
        );

    expect(project('retained'), isNull);
    expect(project('primary'), same(scanned));
    expect(checked, ['retained', 'primary']);
  });

  test('recalled, flash and missing plaintext cannot reappear', () {
    bool neverHidden(String _, String __, DateTime ___) => false;
    expect(
        visibleLocalSearchRow(
            sourceRoomId: 'primary',
            row: row(displayable: false),
            isHidden: neverHidden),
        isNull);
    expect(
        visibleLocalSearchRow(
            sourceRoomId: 'primary',
            row: row(flash: true),
            isHidden: neverHidden),
        isNull);
    expect(
        visibleLocalSearchRow(
            sourceRoomId: 'primary', row: row(text: ''), isHidden: neverHidden),
        isNull);
    expect(
        visibleLocalSearchRow(
            sourceRoomId: 'primary',
            row: row(text: '', media: ChatSearchMediaCategory.imageVideo),
            isHidden: neverHidden),
        isNotNull);
  });
  test('opening an accepted result rechecks its original room', () {
    final results = LocalSearchResultVisibility();
    final scanned = row();
    results.remember('retained', scanned);
    var hidden = false;
    bool isHidden(String roomId, String eventId, DateTime timestamp) {
      expect(roomId, 'retained');
      expect(eventId, scanned.eventId);
      expect(timestamp, scanned.timestamp);
      return hidden;
    }

    expect(results.isVisible(scanned.eventId, isHidden: isHidden), isTrue);
    hidden = true;
    expect(results.isVisible(scanned.eventId, isHidden: isHidden), isFalse);
    results.clear();
    expect(results.isVisible(scanned.eventId, isHidden: isHidden), isFalse);
  });
}
