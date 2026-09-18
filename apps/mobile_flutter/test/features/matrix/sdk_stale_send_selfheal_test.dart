import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 2026-09-19 Mi 6 ANR regression.
///
/// `Event`'s constructor self-heals a stale `sending` event by re-injecting it
/// through `Client.handleSync`. `Client.handleSync` reconstructs events while it
/// persists them (`MatrixSdkDatabase.storeEventUpdate` builds the previous row as
/// an `Event`), so with the unguarded self-heal a single stale `sending` row
/// re-entered sync processing on *every* reconstruction. The result was an
/// endless, purely local stream/microtask flood on the Dart UI isolate: the 1 s
/// timer queue never ran again, no frame was produced, and input dispatch died —
/// the "畅聊 ChatFlow没有响应" ANR. Because the trigger is a local database row,
/// it reproduced on every build (debug and release) and only appeared once a
/// local send had been left in `sending` for longer than
/// `Client.sendTimelineEventTimeout`.
///
/// This test drives the real vendored `MatrixSdkDatabase` on an in-memory
/// sqflite database: it seeds one stale `sending` event and then reconstructs
/// events the way the persistence path does. `Client._handleRooms` records
/// `onSyncStatus.add(...)` for every room of every sync it processes, so counting
/// those emissions counts how many times the constructor managed to re-enter
/// sync processing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  Map<String, dynamic> staleSendingEvent() => <String, dynamic>{
        'type': 'm.room.message',
        'event_id': r'$stale-send',
        'sender': '@me:example',
        'origin_server_ts': DateTime.now()
            .subtract(const Duration(hours: 1))
            .millisecondsSinceEpoch,
        'status': EventStatus.sending.intValue,
        'content': {'msgtype': 'm.text', 'body': 'stale'},
      };

  test(
      'a stale sending event self-heals once instead of pumping Client.handleSync',
      () async {
    final sqflite = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final database = MatrixSdkDatabase(
      'stale_send_selfheal_test',
      database: sqflite,
      sqfliteFactory: databaseFactoryFfi,
    );
    await database.open();
    final client = Client(
      'stale-send-heal',
      databaseBuilder: (_) => database,
    );
    await client.init();
    expect(client.database, isNotNull);

    const roomId = '!stale:example';
    final room = Room(id: roomId, client: client);
    final update = EventUpdate(
      roomID: roomId,
      type: EventUpdateType.timeline,
      content: staleSendingEvent(),
    );
    await database.storeEventUpdate(update, client);

    // Sanity: the row really is stored as `sending`, which is the precondition
    // of the self-heal.
    final stored = await database.getEventById(r'$stale-send', room);
    expect(stored?.status, EventStatus.sending);

    var syncRuns = 0;
    final subscription = client.onSyncStatus.stream.listen((_) => syncRuns++);

    // Reconstruct the way the persistence and timeline paths do.
    for (var i = 0; i < 25; i++) {
      Event.fromJson(Map<String, dynamic>.from(staleSendingEvent()), room);
    }
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(syncRuns, lessThanOrEqualTo(1),
        reason: 'one stale event must self-heal at most once per '
            'sendTimelineEventTimeout window; anything more re-enters '
            'Client.handleSync from event construction and starves the event loop');

    await subscription.cancel();
    await client.dispose();
  });
}
