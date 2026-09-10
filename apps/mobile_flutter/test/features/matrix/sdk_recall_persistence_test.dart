import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Source-only regression coverage: deliberately not executed for this delivery.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  for (final contentTarget in [false, true]) {
    test('redaction survives new events, stale replay and disk reopen '
        '(content target: $contentTarget)', () async {
      final evidence = Directory(
          '../../docs/verification/artifacts/2026-09-10/moments-im-mi6/recall');
      await evidence.create(recursive: true);
      final directory = await evidence.createTemp('sdk-');
      final path = '${directory.path}/matrix.sqlite';
      final client = Client('recall-fixture');
      final room = Room(id: '!room:test', client: client);
      late MatrixSdkDatabase db;
      Future<void> open() async {
        db = MatrixSdkDatabase(path,
            database: await databaseFactoryFfi.openDatabase(path),
            sqfliteFactory: databaseFactoryFfi);
        await db.open();
      }

      Map<String, dynamic> message(String id) => {
            'event_id': id,
            'type': EventTypes.Encrypted,
            'sender': '@sender:test',
            'origin_server_ts': 123,
            'content': {
              'algorithm': 'm.megolm.v1.aes-sha2',
              'ciphertext': 'synthetic-fixture',
            },
          };
      Future<void> store(Map<String, dynamic> event,
              {EventUpdateType type = EventUpdateType.timeline}) =>
          db.storeEventUpdate(
              EventUpdate(roomID: room.id, type: type, content: event), client);
      Future<void> assertRedacted() async {
        final event = await db.getEventById(r'$original', room);
        expect(event, isNotNull);
        expect(event!.redacted, isTrue);
        expect(event.content, isEmpty);
        expect(event.senderId, '@sender:test');
        expect(event.type, EventTypes.Encrypted);
        expect(event.originalSource, isNull);
      }

      await open();
      try {
        await store(message(r'$original'));
        await store({
          'event_id': r'$recall',
          'type': EventTypes.Redaction,
          'sender': '@sender:test',
          'origin_server_ts': 124,
          if (!contentTarget) 'redacts': r'$original',
          'content': {if (contentTarget) 'redacts': r'$original'},
        });
        await assertRedacted();
        await store(message(r'$next'));
        await assertRedacted();
        await store(message(r'$original'), type: EventUpdateType.history);
        await assertRedacted();
        // Limited sync removes fragments while retaining event records. A
        // stale history replay must restore a visible tombstone to the list.
        await db.deleteTimelineForRoom(room.id);
        await store(message(r'$original'), type: EventUpdateType.history);
        expect((await db.getEventList(room)).single.redacted, isTrue);
        await db.close();
        await open();
        await assertRedacted();
        expect((await db.getEventList(room)).single.redacted, isTrue);
        // Another device/reconnect may supply the server's already-redacted
        // encrypted envelope without ever receiving the original plaintext.
        final redacted = (await db.getEventById(r'$original', room))!.toJson();
        await store(redacted);
        await assertRedacted();
      } finally {
        await db.close();
        await client.dispose();
        await databaseFactoryFfi.deleteDatabase(path);
        await directory.delete();
      }
    });
  }

  test('live timeline preserves content-target recall across stale updates',
      () async {
    final client = Client('recall-timeline-fixture');
    final room = Room(id: '!room:test', client: client);
    final timeline = Timeline(room: room, chunk: TimelineChunk(events: []));
    Future<void> deliver(Map<String, dynamic> content) async {
      client.onEvent.add(EventUpdate(
          roomID: room.id, type: EventUpdateType.timeline, content: content));
      await Future<void>.delayed(Duration.zero);
    }

    Map<String, dynamic> original() => {
          'event_id': r'$original',
          'type': EventTypes.Message,
          'sender': '@sender:test',
          'origin_server_ts': 123,
          'content': {'msgtype': 'm.text', 'body': 'synthetic fixture'},
        };
    try {
      await deliver(original());
      await deliver({
        'event_id': r'$recall',
        'type': EventTypes.Redaction,
        'sender': '@sender:test',
        'origin_server_ts': 124,
        'content': {'redacts': r'$original'},
      });
      expect(timeline.events.singleWhere((e) => e.eventId == r'$original').redacted,
          isTrue);
      await deliver(original());
      final event = timeline.events.singleWhere((e) => e.eventId == r'$original');
      expect(event.redacted, isTrue);
      expect(event.content, isEmpty);
    } finally {
      timeline.cancelSubscriptions();
      await client.dispose();
    }
  });
}
