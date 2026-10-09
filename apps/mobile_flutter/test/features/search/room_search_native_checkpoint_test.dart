import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:liuhetong_mobile/features/matrix/room_paged_history_source.dart';
import '../matrix/matrix_room_timeline_adapter_test.dart'
    show RetryClient, RetryRoom, openAdapter;

class ReadStore extends MatrixSdkDatabase {
  ReadStore(super.path, {required super.database});
  int reads = 0;
  bool pause = false;
  @override
  Future<Event?> getEventById(String id, Room room) async {
    reads++;
    final event = await super.getEventById(id, room);
    if (reads == 1) pause = true;
    return event;
  }
}

class StoredClient extends RetryClient {
  StoredClient(this.store);
  final ReadStore store;
  @override
  DatabaseApi get database => store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
      'native maintenance checkpoint stops after one body without accepting page',
      () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final store = ReadStore('search-checkpoint', database: sql);
    await store.open();
    final client = StoredClient(store);
    final room = RetryRoom(client: client);
    client.room = room;
    for (var i = 0; i < 20; i++) {
      await store.storeEventUpdate(
          EventUpdate(
              roomID: room.id,
              type: EventUpdateType.timeline,
              content: {
                'event_id': 'saved-$i',
                'type': 'm.room.message',
                'sender': '@synthetic:test',
                'origin_server_ts': i,
                'content': {'msgtype': 'm.text', 'body': 'fixture'}
              }),
          client);
    }
    final timeline =
        Timeline(room: room, chunk: TimelineChunk(events: const []));
    final adapter = await openAdapter(room, timeline);
    try {
      await expectLater(
          adapter.readHistoryPage(
              direction: RoomHistoryDirection.older,
              rawLimit: 20,
              beforeRead: () async {
                if (store.pause) throw StateError('synthetic pause');
              }),
          throwsStateError);
      expect(store.reads, 1,
          reason:
              'an active body may finish; subsequent bodies must not start');
      store.pause = false;
      final page = await adapter.readHistoryPage(
          direction: RoomHistoryDirection.older, rawLimit: 20);
      expect(page.messages.map((r) => r.id),
          [for (var i = 19; i >= 0; i--) 'saved-$i']);
      expect(page.rawCount, 20);
      expect(page.exhausted, true);
      expect(await store.getTimelineEventCount(room), 20,
          reason: 'maintenance cancellation must not mutate saved history');
    } finally {
      adapter.dispose();
      timeline.cancelSubscriptions();
      await client.dispose();
      await store.close();
    }
  });
}
