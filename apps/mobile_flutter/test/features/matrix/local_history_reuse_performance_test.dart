import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/local_room_history_search.dart';
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';

Future<List<ChatSearchMessage>> collectLocalHits(
    LocalRoomHistorySearch search, String keyword) async {
  final hits = <ChatSearchMessage>[];
  var page = await search.search(ChatSearchFilters(keyword: keyword));
  while (true) {
    hits.addAll(page.items);
    if (page.nextCursor == null) return hits;
    page = await search.search(ChatSearchFilters(keyword: keyword),
        cursor: page.nextCursor);
  }
}

void main() {
  for (final count in [10000, 100000]) {
    test('synthetic $count sparse old matches reuse DB projections', () async {
      final rows = List.generate(
          count,
          (i) => ChatSearchMessage(
              eventId: 'e$i',
              senderId: 'synthetic',
              senderDisplayName: 'synthetic',
              timestamp: DateTime.utc(2026).subtract(Duration(minutes: i)),
              timelineOrder: count - i,
              visibleText: i == count - 100 ? 'rare target' : 'synthetic'));
      var reads = 0, dbProjectedRows = 0, heartbeat = false;
      final search = LocalRoomHistorySearch(
          roomIds: () => ['synthetic'],
          readPage: (_, start, limit) async {
            reads++;
            final page = rows.skip(start).take(limit).toList();
            dbProjectedRows += page.length;
            return page;
          },
          sourceRevision: () => 0,
          project: (_, row) => row);
      Timer.run(() => heartbeat = true);
      final first = Stopwatch()..start();
      expect((await collectLocalHits(search, 'rare')).single.eventId,
          'e${count - 100}');
      first.stop();
      final initialReads = reads, initialProjected = dbProjectedRows;
      expect(heartbeat, isTrue);
      search.cancel();
      final repeat = Stopwatch()..start();
      expect((await collectLocalHits(search, 'target')).single.eventId,
          'e${count - 100}');
      repeat.stop();
      expect(reads, initialReads);
      expect(dbProjectedRows, initialProjected);
      // Synthetic benchmark evidence only; contains no user data.
      // ignore: avoid_print
      print(
          'SYNTHETIC_LOCAL_SEARCH rows=$count first_us=${first.elapsedMicroseconds} repeat_us=${repeat.elapsedMicroseconds} db_pages=$reads first_db_projected=$initialProjected repeat_db_projected=${dbProjectedRows - initialProjected}');
    });
  }
}
