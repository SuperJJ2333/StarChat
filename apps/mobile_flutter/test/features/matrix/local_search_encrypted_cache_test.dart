import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  test(
      'SDK local DB restores decrypted cached message without decryption/network',
      () async {
    final raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final database = MatrixSdkDatabase(inMemoryDatabasePath,
        database: raw, sqfliteFactory: databaseFactoryFfi);
    final client = Client('synthetic-local-search');
    final room = Room(id: '!synthetic:local', client: client);
    final encrypted = <String, dynamic>{
      'event_id': 'cached',
      'sender': '@synthetic:local',
      'type': EventTypes.Encrypted,
      'origin_server_ts': 1000,
      'content': {'algorithm': 'synthetic'}
    };
    await database.open();
    try {
      await database.storeEventUpdate(
          EventUpdate(
              roomID: room.id,
              type: EventUpdateType.timeline,
              content: encrypted),
          client);
      await database.storeEventUpdate(
          EventUpdate(roomID: room.id, type: EventUpdateType.history, content: {
            ...encrypted,
            'type': EventTypes.Message,
            'content': {
              'msgtype': MessageTypes.Text,
              'body': 'synthetic cached text'
            },
            'original_source': encrypted
          }),
          client);
      final events = await database.getEventList(room, start: 0, limit: 512);
      final projected = projectDeviceLocalSearchEvent(events.single);
      expect(projected.visibleText, 'synthetic cached text');
      expect(projected.isUndecrypted, isFalse);
    } finally {
      await database.close();
      await client.dispose();
    }
  });
  test(
      'uncached encryption, hidden/flash and redaction have truthful search coverage',
      () {
    final client = Client('synthetic-projection');
    final room = Room(id: '!synthetic:local', client: client);
    Event event(String type, Map<String, dynamic> content) => Event(
        room: room,
        eventId: 'e',
        type: type,
        content: content,
        senderId: '@synthetic:local',
        originServerTs: DateTime.utc(2026));
    expect(
        projectDeviceLocalSearchEvent(event(EventTypes.Encrypted, {}))
            .isUndecrypted,
        isTrue);
    final flash = projectDeviceLocalSearchEvent(event(EventTypes.Message, {
      'msgtype': MessageTypes.Image,
      'flash': '1',
      'body': 'synthetic private'
    }));
    expect(flash.visibleText, isEmpty);
    expect(flash.isFlashPhoto, isTrue);
    final hidden = projectDeviceLocalSearchEvent(
        event(EventTypes.Message,
            {'msgtype': MessageTypes.Text, 'body': 'synthetic hidden'}),
        hidden: (_, __) => true);
    expect(hidden.visibleText, isEmpty);
    client.dispose();
  });
}
