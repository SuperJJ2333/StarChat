import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../features/matrix/matrix_room_timeline_adapter_test.dart'
    show RetryClient, RetryRoom, openAdapter;

class _MemoryClient extends RetryClient {
  _MemoryClient(this.store);
  final MatrixSdkDatabase store;
  @override
  DatabaseApi get database => store;
}

Future<void> _expectAllSavedRows(MatrixSdkDatabase store, Room room) async {
  final snapshot = await store.openTimelineIdSnapshot(room);
  var seen = 0;
  try {
    expect(snapshot.length, 4500);
    while (true) {
      final page = await snapshot.next(limit: 256);
      expect(page.rawCount, lessThanOrEqualTo(256));
      final rows = await Future.wait(
          page.ids.map((eventId) => store.getEventById(eventId, room)));
      for (var index = 0; index < page.ids.length; index++) {
        final sequence = 4499 - seen++;
        expect(page.ids[index], '\$memory-$sequence');
        expect(rows[index]?.eventId, page.ids[index]);
        expect(rows[index]?.status.isSynced, isTrue);
        expect(rows[index]?.body == 'synthetic $sequence', isTrue,
            reason: 'every saved identifier must retain its original body');
      }
      snapshot.accept(page);
      if (!page.hasMore) break;
    }
    expect(seen, 4500);
  } finally {
    snapshot.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  for (final pending in [false, true]) {
    test(
        '4500 persisted events have a bounded live buffer and reload older rows, pending=$pending',
        () async {
      final artifacts = Directory(
          '../../docs/verification/artifacts/2026-10-08/history-interaction-fix/sdk-resident');
      await artifacts.create(recursive: true);
      final directory = await artifacts.createTemp('live-memory-');
      final path = '${directory.path}/matrix.sqlite';
      final store = MatrixSdkDatabase(path,
          database: await databaseFactoryFfi.openDatabase(path),
          sqfliteFactory: databaseFactoryFfi);
      await store.open();
      final client = _MemoryClient(store);
      final room = RetryRoom(client: client);
      client.room = room;
      late Timeline timeline;
      var storeClosed = false;
      try {
        for (var start = 0; start < 4500; start += 256) {
          await store.transaction(() async {
            for (var i = start; i < (start + 256).clamp(0, 4500); i++) {
              await store.storeEventUpdate(
                  EventUpdate(
                      roomID: room.id,
                      type: EventUpdateType.timeline,
                      content: {
                        'event_id': '\$memory-$i',
                        'type': EventTypes.Message,
                        'sender': '@peer:test',
                        'origin_server_ts': i,
                        'content': {'msgtype': 'm.text', 'body': 'synthetic $i'}
                      }),
                  client);
            }
          });
        }
        timeline = Timeline(
            room: room,
            chunk: TimelineChunk(
                events: await store.getEventList(room, limit: 1000)));
        if (pending) {
          for (final status in [EventStatus.sending, EventStatus.error]) {
            timeline.events.insert(
                0,
                Event(
                    room: room,
                    eventId: 'pending-${status.intValue}',
                    senderId: '@me:test',
                    type: EventTypes.Message,
                    status: status,
                    originServerTs: DateTime.fromMillisecondsSinceEpoch(4501),
                    content: {
                      'msgtype': 'm.text',
                      'body': 'synthetic pending'
                    }));
          }
        }
        final expectedPending = pending ? 2 : 0;
        final adapter = await openAdapter(room, timeline);
        adapter.enableWindow();
        expect(adapter.snapshot().map((m) => m.id), contains('\$memory-4499'));
        expect(timeline.events.length, 1000 + expectedPending);
        await _expectAllSavedRows(store, room);
        final persistedPending =
            await store.getEventList(room, onlySending: true);
        expect(
            persistedPending.every((event) => !event.status.isSynced), isTrue);
        expect(
            persistedPending
                .every((event) => event.eventId.startsWith('pending-')),
            isTrue);
        if (!pending) expect(persistedPending, isEmpty);
        final overlap = timeline.events
            .singleWhere((event) => event.eventId == '\$memory-4000');
        adapter.selectEarlier();
        await timeline.requestHistory(historyCount: 20);
        expect(timeline.events.last.eventId, '\$memory-3480');
        expect(timeline.events.length, 1000 + expectedPending,
            reason:
                'older refill moves the bounded resident slice without deleting history');
        adapter.snapshot();
        expect(timeline.events.length, 1000 + expectedPending);
        expect(timeline.canRequestFuture, isTrue);
        await timeline.requestFuture(historyCount: 20);
        adapter.selectLatest();
        adapter.snapshot();
        expect(timeline.events.length, 1000 + expectedPending);
        expect(
            timeline.events
                .firstWhere((event) => event.status.isSynced)
                .eventId,
            '\$memory-4499');
        expect(
            identical(
                overlap,
                timeline.events
                    .singleWhere((event) => event.eventId == '\$memory-4000')),
            isTrue);
        expect(
            timeline.events
                .where((e) => e.status.isSending || e.status.isError),
            hasLength(expectedPending));
        expect(
            (await store.getEventById('\$memory-0', room))!.body ==
                'synthetic 0',
            isTrue);
        adapter.dispose();
        await store.close();
        storeClosed = true;
        final reopened = MatrixSdkDatabase(path,
            database: await databaseFactoryFfi.openDatabase(path),
            sqfliteFactory: databaseFactoryFfi);
        await reopened.open();
        try {
          await _expectAllSavedRows(reopened, room);
        } finally {
          await reopened.close();
        }
      } finally {
        await client.dispose(closeDatabase: false);
        if (!storeClosed) await store.close();
        await databaseFactoryFfi.deleteDatabase(path);
        await directory.delete();
      }
    });
  }
}
