import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption.dart';
import 'package:liuhetong_mobile/features/matrix/group_announcement_service.dart';
import 'package:liuhetong_mobile/features/matrix/group_room_authority.dart';

const _enabled = bool.fromEnvironment('ANNOUNCEMENT_DIAGNOSTICS');

void main() {
  late DebugPrintCallback previous;
  late List<String> lines;
  setUp(() {
    previous = debugPrint;
    lines = [];
    debugPrint = (String? line, {int? wrapWidth}) {
      if (line != null) lines.add(line);
    };
  });
  tearDown(() => debugPrint = previous);

  test('announcement diagnostics stay silent by default', () async {
    final room = _Room();
    await expectLater(MatrixGroupAnnouncementService(room).load(),
        throwsA(isA<AnnouncementDecryptionUnavailable>()));
    expect(lines, isEmpty);
  }, skip: _enabled);

  test('local diagnostics expose only fixed codes and presence booleans',
      () async {
    final room = _Room();
    final service = MatrixGroupAnnouncementService(room);
    await expectLater(
        service.load(), throwsA(isA<AnnouncementDecryptionUnavailable>()));
    await expectLater(
        service.load(), throwsA(isA<AnnouncementDecryptionUnavailable>()));
    final changed = service.changes.first;
    room.onSessionKeyReceived.add('PRIVATE-SESSION');
    await changed;
    final entries = _entries(lines);
    expect(entries.map((entry) => entry['stage']),
        containsAll(['loaded', 'decrypted', 'key_received']));
    expect(entries.where((entry) => entry['code'] == 'no_session'), isNotEmpty);
    expect(lines.join(), isNot(contains('PRIVATE')));
    for (final entry in entries) {
      expect(
          entry.keys,
          unorderedEquals([
            'stage',
            'code',
            'event_exists',
            'encrypted',
            'bad_encrypted',
            'can_request',
            'has_original',
            'has_ciphertext',
            'has_session',
            'has_sender_key',
            'crypto_enabled',
            'joined'
          ]));
      for (final key
          in entry.keys.where((key) => key != 'stage' && key != 'code')) {
        expect(entry[key], isA<bool>());
      }
    }
  }, skip: !_enabled);

  for (final body in <String, String>{
    'The sender has not sent us the session key.': 'no_session',
    'UNKNOWN_MESSAGE_INDEX': 'unknown_index',
    'Exception: UNKNOWN_MESSAGE_INDEX': 'unknown_index',
    'Unknown encryption algorithm.': 'unsupported',
    'The secure channel with the sender was corrupted.': 'corrupted',
    'PRIVATE-BODY UNKNOWN_MESSAGE_INDEX PRIVATE-KEY': 'other',
  }.entries) {
    test('diagnostic whitelist maps ${body.value} without copying body',
        () async {
      final room = _Room()..body = body.key;
      await expectLater(MatrixGroupAnnouncementService(room).load(),
          throwsA(isA<AnnouncementDecryptionUnavailable>()));
      expect(_entries(lines).last['code'], body.value);
      expect(lines.join(), isNot(contains(body.key)));
      expect(lines.join(), isNot(contains('PRIVATE')));
    }, skip: !_enabled);
  }

  test('request exceptions never reach the diagnostic payload', () async {
    final room = _Room()..failRequest = true;
    await expectLater(MatrixGroupAnnouncementService(room).load(),
        throwsA(isA<AnnouncementDecryptionUnavailable>()));
    expect(_entries(lines).last['stage'], 'decrypted');
    expect(lines.join(), isNot(contains('PRIVATE')));
  }, skip: !_enabled);

  test('decrypted message body is never interpreted as a failure', () async {
    final room = _Room()..decrypted = true;
    expect((await MatrixGroupAnnouncementService(room).load()).preview,
        'PRIVATE-PLAINTEXT');
    expect(_entries(lines).last['code'], 'none');
    expect(lines.join(), isNot(contains('PRIVATE')));
  }, skip: !_enabled);
}

List<Map<String, dynamic>> _entries(List<String> lines) => [
      for (final line in lines)
        if (line.startsWith('ANNOUNCEMENT_DIAGNOSTIC '))
          jsonDecode(line.substring('ANNOUNCEMENT_DIAGNOSTIC '.length))
              as Map<String, dynamic>
    ];

class _Client extends Client {
  _Client() : super('PRIVATE-CLIENT');
  @override
  String get userID => '@PRIVATE-USER:test';
  @override
  bool get encryptionEnabled => true;
  late final crypto = _Encryption(this);
  @override
  Encryption get encryption => crypto;
}

class _Room extends Room {
  _Room() : super(id: '!PRIVATE-ROOM:test', client: _Client()) {
    setState(Event(
        type: groupAnnouncementStateType,
        content: {'event_id': r'$PRIVATE-EVENT'},
        senderId: '@PRIVATE-SENDER:test',
        room: this,
        eventId: r'$PRIVATE-REFERENCE',
        stateKey: '',
        originServerTs: DateTime(2026)));
  }
  String body = 'The sender has not sent us the session key.';
  bool failRequest = false;
  bool decrypted = false;
  @override
  Future<Event?> getEventById(String eventID) async => Event(
      type: EventTypes.Encrypted,
      content: {
        'ciphertext': 'PRIVATE-CIPHERTEXT',
        'algorithm': AlgorithmTypes.megolmV1AesSha2,
        'sender_key': 'PRIVATE-KEY',
        'session_id': 'PRIVATE-SESSION'
      },
      senderId: '@PRIVATE-SENDER:test',
      room: this,
      eventId: eventID,
      originServerTs: DateTime(2026));
}

class _Encryption extends Encryption {
  _Encryption(Client client) : super(client: client);
  @override
  Future<Event> decryptRoomEvent(String roomId, Event event,
      {bool store = false,
      EventUpdateType updateType = EventUpdateType.timeline}) async {
    final room = event.room as _Room;
    if (room.decrypted) {
      return Event(
          type: EventTypes.Message,
          content: const GroupAnnouncement(
              [AnnouncementBlock.text('PRIVATE-PLAINTEXT')]).toContent(),
          senderId: event.senderId,
          room: room,
          eventId: event.eventId,
          originServerTs: event.originServerTs,
          originalSource: event);
    }
    return _RequestEvent(room, event);
  }
}

class _RequestEvent extends Event {
  _RequestEvent(_Room room, Event original)
      : super(
            type: EventTypes.Encrypted,
            content: {
              'msgtype': MessageTypes.BadEncrypted,
              'body': room.body,
              'can_request_session': true,
              'session_id': 'PRIVATE-SESSION',
              'sender_key': 'PRIVATE-KEY',
              'ciphertext': 'PRIVATE-CIPHERTEXT',
            },
            senderId: original.senderId,
            room: room,
            eventId: original.eventId,
            originServerTs: original.originServerTs,
            originalSource: original);
  @override
  Future<void> requestKey() async {
    if ((room as _Room).failRequest) throw StateError('PRIVATE-EXCEPTION');
  }
}
