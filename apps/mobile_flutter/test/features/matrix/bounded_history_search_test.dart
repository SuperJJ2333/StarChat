import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/bounded_history_search.dart';
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';

ChatSearchMessage message(int id) => ChatSearchMessage(
    eventId: '$id',
    senderId: 'sender',
    senderDisplayName: 'Name',
    timestamp: DateTime.utc(2026),
    timelineOrder: id,
    visibleText: id == 1 ? 'needle' : 'ordinary');

void main() {
  test('indexed continuation does not rescan the loaded prefix after each page',
      () async {
    var oldest = 700;
    var visited = 0;
    Iterable<int> rows(String? before) sync* {
      final newest = before == null ? 999 : int.parse(before) - 1;
      for (var id = newest; id >= oldest; id--) {
        visited++;
        yield id;
      }
    }

    final source = BoundedHistorySearch<int>(
        snapshot: () => rows(null),
        snapshotBefore: rows,
        eventId: (id) => '$id',
        project: message,
        exhausted: () => oldest == 0,
        loadEarlier: () async {
          oldest = (oldest - 100).clamp(0, 999);
        });
    var result =
        await source.search(const ChatSearchFilters(keyword: 'needle'));
    for (var i = 0; i < 5 && result.nextCursor != null; i++) {
      result = await source.search(const ChatSearchFilters(keyword: 'needle'),
          cursor: result.nextCursor);
    }
    expect(result.items.map((m) => m.eventId), contains('1'));
    expect(visited, 1000, reason: 'one visit per row across all loaded pages');
  });
  test('resume scans a final page that completed after the previous budget',
      () async {
    final pending = Completer<void>();
    final rows = [2];
    var complete = false;
    final source = BoundedHistorySearch<int>(
      snapshot: () => rows.toList(),
      eventId: (id) => '$id',
      project: message,
      exhausted: () => complete,
      loadEarlier: () => pending.future,
      budget: const Duration(milliseconds: 10),
    );
    final first =
        await source.search(const ChatSearchFilters(keyword: 'needle'));
    expect(first.nextCursor, isNotNull);
    rows.add(1);
    complete = true;
    pending.complete();
    await Future<void>.delayed(Duration.zero);
    final next = await source.search(const ChatSearchFilters(keyword: 'needle'),
        cursor: first.nextCursor);
    expect(next.items.map((m) => m.eventId), ['1']);
    expect(next.nextCursor, isNull);
  });
  test('sparse query stops at page budget and can resume to old match',
      () async {
    var loaded = 60;
    var loads = 0;
    final source = BoundedHistorySearch<int>(
      snapshot: () => List.generate(loaded, (i) => 600 - i),
      eventId: (id) => '$id',
      project: message,
      exhausted: () => loaded == 600,
      loadEarlier: () async {
        loads++;
        loaded += 60;
      },
    );
    var result =
        await source.search(const ChatSearchFilters(keyword: 'needle'));
    expect(loads, 3);
    expect(result.items, isEmpty);
    expect(result.nextCursor, isNotNull);
    for (var i = 0; i < 5 && result.nextCursor != null; i++) {
      result = await source.search(const ChatSearchFilters(keyword: 'needle'),
          cursor: result.nextCursor);
    }
    expect(result.items.map((m) => m.eventId), contains('1'));
    expect(loads, 9);
  });

  test('already loaded history has bounded work and yields to event queue',
      () async {
    var projections = 0;
    var eventQueueRan = false;
    final source = BoundedHistorySearch<int>(
      snapshot: () => Iterable.generate(10000, (i) => 10000 - i),
      eventId: (id) => '$id',
      project: (id) {
        projections++;
        return message(id);
      },
      exhausted: () => true,
      loadEarlier: () async {},
    );
    Timer.run(() => eventQueueRan = true);
    final result =
        await source.search(const ChatSearchFilters(keyword: 'absent'));
    expect(projections, 600);
    expect(result.nextCursor, isNotNull);
    expect(eventQueueRan, isTrue);
    await source.search(const ChatSearchFilters(keyword: 'absent'),
        cursor: result.nextCursor);
    expect(projections, 1200,
        reason: 'each row projected once, not full history again');
  });

  test('cancel stops old lookup after awaited page and new query is isolated',
      () async {
    final pending = Completer<void>();
    var loads = 0;
    final source = BoundedHistorySearch<int>(
      snapshot: () => [2],
      eventId: (id) => '$id',
      project: message,
      exhausted: () => false,
      loadEarlier: () {
        loads++;
        return pending.future;
      },
    );
    final old = source.search(const ChatSearchFilters(keyword: 'absent'));
    await Future<void>.delayed(Duration.zero);
    source.cancel();
    pending.complete();
    await expectLater(old, throwsA(isA<HistorySearchCancelled>()));
    expect(loads, 1);
  });

  test('no progress is incomplete, not proof of empty full history', () async {
    final source = BoundedHistorySearch<int>(
      snapshot: () => [2],
      eventId: (id) => '$id',
      project: message,
      exhausted: () => false,
      loadEarlier: () async {},
    );
    final result =
        await source.search(const ChatSearchFilters(keyword: 'absent'));
    expect(result.items, isEmpty);
    expect(result.nextCursor, isNotNull);
  });
}
