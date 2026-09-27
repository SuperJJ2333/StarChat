import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/local_room_history_search.dart';
import 'package:liuhetong_mobile/features/matrix/bounded_history_search.dart';
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';

ChatSearchMessage message(int i, {String body = 'synthetic'}) =>
    ChatSearchMessage(
        eventId: 'e$i',
        senderId: 'synthetic',
        senderDisplayName: 'synthetic',
        timestamp: DateTime.utc(2026, 9, 27).subtract(Duration(days: i)),
        timelineOrder: 20000 - i,
        visibleText: body);

void main() {
  test('revision change during DB await discards stale rows before projection',
      () async {
    var revision = 0;
    var reads = 0, projections = 0;
    final gate = Completer<List<ChatSearchMessage>>();
    final search = LocalRoomHistorySearch(
        roomIds: () => ['room'],
        sourceRevision: () => revision,
        readPage: (_, __, ___) async {
          if (reads++ == 0) return gate.future;
          return [message(2, body: 'hit')];
        },
        project: (_, row) {
          projections++;
          return row;
        });
    final pending = search.search(const ChatSearchFilters(keyword: 'hit'));
    revision++;
    gate.complete([message(1, body: 'withdrawn hit')]);
    await expectLater(pending, throwsA(isA<HistorySearchCancelled>()));
    expect(projections, 0);
    expect(
        (await search.search(const ChatSearchFilters(keyword: 'hit')))
            .items
            .single
            .eventId,
        'e2');
  });
  test('revision change at scan yield discards partial hits and retries cursor',
      () async {
    var revision = 0, reads = 0;
    var rows = List.generate(130, (i) => message(i, body: 'hit'));
    final search = LocalRoomHistorySearch(
        roomIds: () => ['room'],
        sourceRevision: () => revision,
        readPage: (_, start, limit) async {
          reads++;
          return rows.skip(start).take(limit).toList();
        },
        project: (_, row) => row);
    final first =
        await search.search(const ChatSearchFilters(keyword: 'hit'), limit: 1);
    final pending = search.search(const ChatSearchFilters(keyword: 'hit'),
        cursor: first.nextCursor, limit: 100);
    Timer.run(() {
      rows = [message(0, body: 'hit'), message(129, body: 'hit')];
      revision++;
    });
    await expectLater(pending, throwsA(isA<HistorySearchCancelled>()));
    final retry = await search.search(const ChatSearchFilters(keyword: 'hit'),
        cursor: first.nextCursor, limit: 100);
    expect(retry.items.map((m) => m.eventId), ['e129']);
    expect(reads, 2);
  });
  test(
      'source revision rereads off-window recall without duplicating prior hits',
      () async {
    var revision = 0;
    var rows = [
      message(1, body: 'hit'),
      message(2, body: 'hit'),
      message(3, body: 'hit')
    ];
    final search = LocalRoomHistorySearch(
        roomIds: () => ['room'],
        sourceRevision: () => revision,
        readPage: (_, start, limit) async =>
            rows.skip(start).take(limit).toList(),
        project: (_, row) => row);
    final first =
        await search.search(const ChatSearchFilters(keyword: 'hit'), limit: 1);
    rows = [
      message(1, body: 'hit'),
      message(2, body: ''),
      message(3, body: 'hit')
    ];
    revision++;
    final next = await search.search(const ChatSearchFilters(keyword: 'hit'),
        cursor: first.nextCursor, limit: 2);
    expect(next.items.map((m) => m.eventId), ['e3']);
  });
  test('dense 10000-hit first page reads one bounded DB page', () async {
    final rows = List.generate(10000, (i) => message(i, body: 'hit'));
    var reads = 0;
    final search = LocalRoomHistorySearch(
        roomIds: () => ['room'],
        readPage: (_, start, limit) async {
          reads++;
          return rows.skip(start).take(limit).toList();
        },
        project: (_, row) => row);
    final first = await search.search(const ChatSearchFilters(keyword: 'hit'));
    expect(first.items.length, 50);
    expect(reads, 1);
    final second = await search.search(const ChatSearchFilters(keyword: 'hit'),
        cursor: first.nextCursor);
    expect(second.items.first.eventId, 'e50');
    expect(reads, 1);
    expect(
        {
          ...first.items.map((m) => m.eventId),
          ...second.items.map((m) => m.eventId)
        }.length,
        100);
  });
  test('missing decrypted cache marks incomplete coverage', () async {
    final search = LocalRoomHistorySearch(
        roomIds: () => ['room'],
        readPage: (_, __, ___) async => [
              ChatSearchMessage(
                  eventId: 'encrypted',
                  senderId: 'synthetic',
                  senderDisplayName: 'synthetic',
                  timestamp: DateTime.utc(2026),
                  timelineOrder: 1,
                  visibleText: '',
                  isUndecrypted: true)
            ],
        project: (_, row) => row.isUndecrypted ? null : row);
    final result = await search.search(const ChatSearchFilters(keyword: 'hit'));
    expect(result.items, isEmpty);
    expect(result.coverageIncomplete, isTrue);
    expect(result.nextCursor, isNull);
  });
  test('first query includes old device history without UI pagination',
      () async {
    final rows = List.generate(
        10000, (i) => message(i, body: i == 9000 ? 'needle' : 'synthetic'));
    final reads = <int>[];
    final search = LocalRoomHistorySearch(
        roomIds: () => ['room'],
        readPage: (_, start, limit) async {
          reads.add(limit);
          return rows.skip(start).take(limit).toList();
        },
        project: (_, row) => row);
    final result =
        await search.search(const ChatSearchFilters(keyword: 'needle'));
    expect(result.items.single.eventId, 'e9000');
    expect(result.nextCursor, isNull);
    expect(reads, everyElement(512));
    expect(reads.length, 20);
  });
  test('query cancellation discards delayed account-local reads', () async {
    final gate = Completer<List<ChatSearchMessage>>();
    final search = LocalRoomHistorySearch(
        roomIds: () => ['room'],
        readPage: (_, __, ___) => gate.future,
        project: (_, row) => row);
    final pending = search.search(const ChatSearchFilters(keyword: 'needle'));
    search.cancel();
    gate.complete([message(1, body: 'needle')]);
    await expectLater(pending, throwsA(isA<HistorySearchCancelled>()));
  });
  test('retained rooms merge, dedupe and paginate without rereading DB',
      () async {
    var reads = 0;
    final search = LocalRoomHistorySearch(
        roomIds: () => ['primary', 'retained'],
        readPage: (room, _, __) async {
          reads++;
          return room == 'primary'
              ? [message(1, body: 'hit'), message(3, body: 'hit')]
              : [message(2, body: 'hit'), message(3, body: 'hit')];
        },
        project: (_, row) => row);
    final first =
        await search.search(const ChatSearchFilters(keyword: 'hit'), limit: 2);
    expect(first.items.map((m) => m.eventId), ['e1', 'e2']);
    final next = await search.search(const ChatSearchFilters(keyword: 'hit'),
        cursor: first.nextCursor, limit: 2);
    expect(next.items.map((m) => m.eventId), ['e3']);
    expect(next.nextCursor, isNull);
    expect(reads, 2);
  });
  test('projection rejects hidden/recalled rows and failures remain retryable',
      () async {
    var fail = true;
    final search = LocalRoomHistorySearch(
        roomIds: () => ['room'],
        readPage: (_, __, ___) async {
          if (fail) throw StateError('synthetic read failure');
          return [message(1, body: 'hit'), message(2, body: 'hit')];
        },
        project: (_, row) => row.eventId == 'e1' ? null : row);
    await expectLater(search.search(const ChatSearchFilters(keyword: 'hit')),
        throwsStateError);
    fail = false;
    expect(
        (await search.search(const ChatSearchFilters(keyword: 'hit')))
            .items
            .single
            .eventId,
        'e2');
  });
}
