import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/local_room_history_snapshot.dart';
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';
import 'package:liuhetong_mobile/features/matrix/bounded_history_search.dart';
import 'package:liuhetong_mobile/features/matrix/room_history_day_index.dart';

ChatSearchMessage row(String id, int day,
        {bool visible = true, bool flash = false}) =>
    ChatSearchMessage(
        eventId: id,
        senderId: 'synthetic',
        senderDisplayName: 'synthetic',
        timestamp: DateTime(2026, 9, day),
        timelineOrder: day,
        visibleText: 'synthetic',
        isDisplayable: visible,
        isFlashPhoto: flash);
void main() {
  test('calendar scans all local sources and disables truly empty gap dates',
      () async {
    var reads = 0;
    final snapshot = LocalRoomHistorySnapshot(
        roomIds: () => ['primary', 'retained'],
        readPage: (room, start, limit) async {
          reads++;
          return start > 0
              ? []
              : room == 'primary'
                  ? [
                      row('recent', 25),
                      row('hidden', 12, visible: false),
                      row('flash', 24, flash: true)
                    ]
                  : [row('old', 1)];
        });
    final days = await snapshot.monthDays(const CalendarMonth(2026, 9));
    expect(days.coverageComplete, isTrue);
    expect(days.stateOf(25), RoomHistoryDayState.knownPresent);
    expect(days.stateOf(24), RoomHistoryDayState.knownPresent);
    expect(days.stateOf(1), RoomHistoryDayState.knownPresent);
    expect(days.stateOf(12), RoomHistoryDayState.knownEmpty);
    expect(days.stateOf(15), RoomHistoryDayState.knownEmpty);
    expect(days.anchors[1], 'old');
    await snapshot.monthDays(const CalendarMonth(2026, 8));
    expect(reads, 2);
  });
  test(
      'source set, recall/decryption revision and session clear invalidate reused dates',
      () async {
    var revision = 0, reads = 0;
    var rooms = ['primary'];
    var rows = [row('a', 1)];
    final snapshot = LocalRoomHistorySnapshot(
        roomIds: () => rooms,
        sourceRevision: () => revision,
        readPage: (_, __, ___) async {
          reads++;
          return rows;
        });
    expect((await snapshot.monthDays(const CalendarMonth(2026, 9))).anchors[1],
        'a');
    rows = [row('b', 2)];
    revision++;
    final next = await snapshot.monthDays(const CalendarMonth(2026, 9));
    expect(next.stateOf(1), RoomHistoryDayState.knownEmpty);
    expect(next.anchors[2], 'b');
    rooms = ['primary', 'retained'];
    await snapshot.monthDays(const CalendarMonth(2026, 9));
    expect(reads, 4);
    snapshot.clear();
    await snapshot.monthDays(const CalendarMonth(2026, 9));
    expect(reads, 6);
  });
  test(
      'missing event rows preserve fragment positions and cannot truncate old history',
      () async {
    final missing = completeLocalHistoryPage(['gone', 'old'], [row('old', 1)]);
    expect(missing.length, 2);
    expect(missing.first.isDisplayable, isFalse);
    expect(missing.first.isUndecrypted, isTrue);
    final snapshot = LocalRoomHistorySnapshot(
        roomIds: () => ['room'],
        pageSize: 2,
        readPage: (_, offset, __) async => offset == 0
            ? missing
            : offset == 2
                ? [row('earlier', 2)]
                : []);
    final days = await snapshot.monthDays(const CalendarMonth(2026, 9));
    expect(days.anchors.values, containsAll(['old', 'earlier']));
  });
  test(
      'failed/in-flight changing snapshot never publishes confirmed empty dates and can retry',
      () async {
    var rev = 0, fail = true;
    final snapshot = LocalRoomHistorySnapshot(
        roomIds: () => ['room'],
        sourceRevision: () => rev,
        readPage: (_, __, ___) async {
          if (fail) throw StateError('synthetic');
          return [row('ok', 2)];
        });
    await expectLater(
        snapshot.monthDays(const CalendarMonth(2026, 9)), throwsStateError);
    fail = false;
    expect((await snapshot.monthDays(const CalendarMonth(2026, 9))).anchors[2],
        'ok');
    final pending = Completer<List<ChatSearchMessage>>();
    final changed = LocalRoomHistorySnapshot(
        roomIds: () => ['room'],
        sourceRevision: () => rev,
        readPage: (_, __, ___) => pending.future);
    final load = changed.monthDays(const CalendarMonth(2026, 9));
    rev++;
    pending.complete([row('stale', 1)]);
    await expectLater(load, throwsA(isA<HistorySearchCancelled>()));
  });
  test(
      'cache eviction never changes coverage and concurrent page readers are single-flight',
      () async {
    var reads = 0;
    final gate = Completer<List<ChatSearchMessage>>();
    final snapshot = LocalRoomHistorySnapshot(
        roomIds: () => ['room'],
        maxCachedRows: 1,
        readPage: (_, __, ___) {
          reads++;
          return gate.future;
        });
    final first = snapshot.page('room', 0, 512),
        second = snapshot.page('room', 0, 512);
    gate.complete([row('a', 1), row('b', 2)]);
    expect((await first).length, 2);
    expect((await second).length, 2);
    expect(reads, 1);
    expect(
        (await snapshot.monthDays(const CalendarMonth(2026, 9))).anchors.length,
        2);
  });
}
