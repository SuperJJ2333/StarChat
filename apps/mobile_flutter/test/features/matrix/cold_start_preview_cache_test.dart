import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/decryption_state_controller.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'matrix_client_factory_test.dart' show SnapshotClient, SnapshotRoom;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SnapshotClient client;
  late SnapshotRoom room;
  late MatrixSdkE2eeClient matrix;

  Map<String, dynamic> decrypted() => {
        'event_id': r'$latest',
        'type': EventTypes.Message,
        'sender': '@me:test',
        'origin_server_ts': 123,
        'content': {'msgtype': 'm.text', 'body': 'synthetic cached text'},
      };

  Event redaction() => Event.fromJson({
        'event_id': r'$recall',
        'type': EventTypes.Redaction,
        'sender': '@me:test',
        'origin_server_ts': 124,
        'content': {'redacts': r'$latest'},
      }, room);

  Future<void> emit(Map<String, dynamic> event, EventUpdateType type) async {
    client.onEvent
        .add(EventUpdate(roomID: room.id, type: type, content: event));
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    client = SnapshotClient();
    room = SnapshotRoom(id: '!preview:test', client: client, joined: true)
      ..snapshotEvent = Event.fromJson({
        ...decrypted(),
        'type': EventTypes.Encrypted,
        'content': {
          'algorithm': 'm.megolm.v1.aes-sha2',
          'ciphertext': 'synthetic'
        },
      }, Room(id: '!preview:test', client: client));
    client.snapshotRooms.add(room);
    matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://test'), suspendClient: (_) async {});
    await matrix.conversations.snapshot();
    await emit(decrypted(), EventUpdateType.decryptedTimelineQueue);
    expect((await matrix.conversations.snapshot()).rooms.single.lastEvent!.body,
        'synthetic cached text');
  });

  tearDown(() async {
    await matrix.suspend();
    await client.dispose();
  });

  test('4500 decrypted arrivals retain a bounded recent preview window',
      () async {
    for (var i = 0; i < 4500; i++) {
      final event = {...decrypted(), 'event_id': '\$burst-$i'};
      room.snapshotEvent = Event.fromJson({
        ...event,
        'type': EventTypes.Encrypted,
        'content': {
          'algorithm': 'm.megolm.v1.aes-sha2',
          'ciphertext': 'synthetic'
        },
      }, room);
      await emit(event, EventUpdateType.decryptedTimelineQueue);
    }
    expect(matrix.debugDecryptedPreviewCount, lessThanOrEqualTo(32));
    final preview =
        (await matrix.conversations.snapshot()).rooms.single.lastEvent!;
    expect(preview.eventId, '\$burst-4499');
    expect(preview.body, 'synthetic cached text');
  });

  test('authoritative recall overrides an older decrypted preview cache',
      () async {
    room.snapshotEvent!.setRedactionEvent(redaction());
    final event =
        (await matrix.conversations.snapshot()).rooms.single.lastEvent!;
    expect(event.redacted, isTrue);
    expect(event.content, isEmpty);
    expect(event.decryptionState, MessageDecryptionState.decrypted,
        reason: 'a known recall needs no key and must render consistently');
  });

  test('late decryption of old history cannot evict the current room head',
      () async {
    for (var i = 0; i < 100; i++) {
      await emit(
          {...decrypted(), 'event_id': '\$old-$i', 'origin_server_ts': i - 100},
          EventUpdateType.decryptedTimelineQueue);
    }
    final preview =
        (await matrix.conversations.snapshot()).rooms.single.lastEvent!;
    expect(preview.body, 'synthetic cached text');
    expect(matrix.debugDecryptedPreviewCount, lessThanOrEqualTo(32));
  });

  for (final contentTarget in [false, true]) {
    test(
        'recall invalidates preview and rejects late plaintext replay '
        '(content target: $contentTarget)', () async {
      final recall = redaction().toJson();
      if (!contentTarget) {
        recall['redacts'] = r'$latest';
        recall['content'] = <String, dynamic>{};
      }
      room.snapshotEvent!.setRedactionEvent(Event.fromJson(recall, room));
      await emit(recall, EventUpdateType.timeline);
      expect(matrix.debugDecryptedPreviewCount, 0,
          reason: 'redaction must discard cached plaintext immediately');
      await emit(decrypted(), EventUpdateType.decryptedTimelineQueue);
      expect(matrix.debugDecryptedPreviewCount, 0,
          reason: 'late decryption cannot cache plaintext for a recalled head');
      final event =
          (await matrix.conversations.snapshot()).rooms.single.lastEvent!;
      expect(event.redacted, isTrue);
      expect(event.content, isEmpty);
    });
  }

  test('already-redacted timeline envelope discards cached plaintext',
      () async {
    room.snapshotEvent!.setRedactionEvent(redaction());
    await emit(room.snapshotEvent!.toJson(), EventUpdateType.timeline);
    expect(matrix.debugDecryptedPreviewCount, 0);
    await emit(decrypted(), EventUpdateType.decryptedTimelineQueue);
    expect(matrix.debugDecryptedPreviewCount, 0);
    expect(
        (await matrix.conversations.snapshot())
            .rooms
            .single
            .lastEvent!
            .redacted,
        isTrue);
  });
}
