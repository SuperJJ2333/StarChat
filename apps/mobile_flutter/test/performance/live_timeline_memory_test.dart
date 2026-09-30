import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../features/matrix/matrix_room_timeline_adapter_test.dart'
    show RetryClient, RetryRoom, openAdapter;

class _MemoryClient extends RetryClient {
  _MemoryClient(this.store);
  final MatrixSdkDatabase store;
  @override
  DatabaseApi get database => store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  for (final pending in [false, true]) {
    test(
        '4500 persisted events have a bounded live buffer and reload older rows, pending=$pending',
        () async {
      final artifacts = Directory(
          '../../docs/verification/artifacts/2026-09-30/mobile-perf-mute-media');
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
      try {
        await store.transaction(() async {
          for (var i = 0; i < 4500; i++) {
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
        timeline = Timeline(
            room: room,
            chunk: TimelineChunk(events: await store.getEventList(room)));
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
        expect((await store.getEventList(room)).length, 4500,
            reason:
                'trimming presentation memory must not delete stored history');
        adapter.selectEarlier();
        await timeline.requestHistory(historyCount: 20);
        expect(timeline.events.last.eventId, '\$memory-3480');
        expect(timeline.events.length, 1020 + expectedPending,
            reason:
                'explicit history paging is retained while reading history');
        adapter.snapshot();
        expect(timeline.events.length, 1020 + expectedPending);
        adapter.selectLatest();
        adapter.snapshot();
        expect(timeline.events.length, 1000 + expectedPending);
        expect(
            timeline.events
                .where((e) => e.status.isSending || e.status.isError),
            hasLength(expectedPending));
        expect((await store.getEventById('\$memory-0', room))!.body,
            'synthetic 0');
        adapter.dispose();
      } finally {
        await client.dispose(closeDatabase: false);
        await store.close();
        await databaseFactoryFfi.deleteDatabase(path);
        await directory.delete();
      }
    });
  }
}
