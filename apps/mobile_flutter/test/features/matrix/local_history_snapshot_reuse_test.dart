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
  test('changing keyword reuses stable device-local DB projections', () async {
    var reads = 0;
    final rows = List.generate(
        10000,
        (i) => ChatSearchMessage(
            eventId: 'e$i',
            senderId: 'synthetic',
            senderDisplayName: 'synthetic',
            timestamp: DateTime.utc(2026, 9, 1),
            timelineOrder: 10000 - i,
            visibleText: i == 9000 ? 'needle alpha' : 'synthetic'));
    final search = LocalRoomHistorySearch(
        roomIds: () => ['room'],
        sourceRevision: () => 0,
        readPage: (_, start, limit) async {
          reads++;
          return rows.skip(start).take(limit).toList();
        },
        project: (_, row) => row);
    expect((await collectLocalHits(search, 'needle')).single.eventId, 'e9000');
    final firstReads = reads;
    search.cancel();
    expect((await collectLocalHits(search, 'alpha')).single.eventId, 'e9000');
    expect(reads, firstReads,
        reason: 'unchanged local projections survive query cancellation');
  });
}
