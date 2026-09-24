import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/encryption/utils/session_key.dart';
// Native libolm is the only decryption seam; the SDK's missing-session,
// originalSource, replay tracking and key-request logic run unchanged.
// ignore: depend_on_referenced_packages
import 'package:olm/olm.dart' as olm;
import 'package:liuhetong_mobile/features/matrix/group_announcement_service.dart';
import 'package:liuhetong_mobile/features/matrix/group_room_authority.dart';

void main() {
  test(
      'historical key index failure requires republish until a valid key arrives',
      () async {
    final client = _Client();
    final room = _Room(client);
    client.crypto.keyManager.recover(room, failOldIndex: true);
    final service = MatrixGroupAnnouncementService(room);
    await expectLater(
        service.load(), throwsA(isA<AnnouncementDecryptionUnavailable>()));
    expect(client.requests, isEmpty);
    final changed = service.changes.first;
    client.crypto.keyManager.recover(room);
    await changed;
    expect((await service.load()).preview, 'recovered historical announcement');
  });

  test('unsupported encrypted announcement is not waiting for a key', () async {
    final client = _Client()..algorithm = 'unsupported.algorithm';
    final room = _Room(client);
    await expectLater(MatrixGroupAnnouncementService(room).load(),
        throwsA(isA<AnnouncementDecryptionUnavailable>()));
    expect(client.requests, isEmpty);
  });

  test('historical announcement never explicitly requests missing keys',
      () async {
    final client = _Client();
    final room = _Room(client);
    client.rooms.add(room);
    final service = MatrixGroupAnnouncementService(room);
    await expectLater(
        service.load(), throwsA(isA<AnnouncementDecryptionUnavailable>()));
    expect(client.requests, isEmpty);
    // Rebuilds and room syncs must not create a key-request storm.
    await expectLater(MatrixGroupAnnouncementService(room).load(),
        throwsA(isA<AnnouncementDecryptionUnavailable>()));
    expect(client.requests, isEmpty);
    final changed = service.changes.first;
    client.crypto.keyManager.recover(room);
    await changed;
    expect((await service.load()).preview, 'recovered historical announcement');
    expect(client.requests, isEmpty);
  });

  test('member leaving before recovery cannot request or read keys', () async {
    final client = _Client();
    final room = _Room(client)..membership = Membership.leave;
    await expectLater(
        MatrixGroupAnnouncementService(room).load(), throwsStateError);
    expect(client.requests, isEmpty);
  });

  test('cached failed projection retries its original ciphertext', () async {
    final client = _Client();
    final room = _Room(client);
    final original = Event.fromMatrixEvent(
        await client.getOneRoomEvent(room.id, r'$historical-announcement'),
        room);
    room.cached = Event(
        type: EventTypes.Encrypted,
        content: {'msgtype': MessageTypes.BadEncrypted, 'body': 'old failure'},
        senderId: original.senderId,
        room: room,
        eventId: original.eventId,
        originServerTs: original.originServerTs,
        originalSource: original);
    client.crypto.keyManager.recover(room);
    expect((await MatrixGroupAnnouncementService(room).load()).preview,
        'recovered historical announcement');
    expect(client.requests, isEmpty);
  });

  test('mismatched announcement publisher cannot trigger key request',
      () async {
    final client = _Client();
    final room = _Room(client);
    room.setState(Event(
        type: groupAnnouncementStateType,
        content: {'event_id': r'$historical-announcement'},
        senderId: '@other:test',
        room: room,
        eventId: r'$other-reference',
        stateKey: '',
        originServerTs: DateTime(2026)));
    await expectLater(
        MatrixGroupAnnouncementService(room).load(), throwsStateError);
    expect(client.requests, isEmpty);
  });
}

class _Client extends Client {
  _Client() : super('announcement-sdk-recovery');
  @override
  String get userID => '@member:test';
  @override
  String get deviceID => 'DEVICE';
  @override
  bool get encryptionEnabled => true;
  late final crypto = _Encryption(this);
  @override
  Encryption get encryption => crypto;
  final requests = <Map<String, dynamic>>[];
  String algorithm = AlgorithmTypes.megolmV1AesSha2;
  void Function()? onRequest;
  @override
  Future<void> sendToDevicesOfUserIds(
      Set<String> users, String eventType, Map<String, dynamic> message,
      {String? messageId}) async {
    expect(eventType, EventTypes.RoomKeyRequest);
    expect(users, {'@member:test', '@owner:test'});
    requests.add(message);
    onRequest?.call();
  }

  @override
  Future<MatrixEvent> getOneRoomEvent(String roomId, String eventId) async =>
      MatrixEvent.fromJson({
        'event_id': eventId,
        'sender': '@owner:test',
        'origin_server_ts': 1,
        'type': EventTypes.Encrypted,
        'content': {
          'algorithm': algorithm,
          'session_id': 'historical-session',
          'sender_key': 'sender-key',
          'ciphertext': 'native-ciphertext-fixture',
        },
      });
}

class _Room extends Room {
  _Room(_Client client) : super(id: '!announcement:test', client: client) {
    setState(Event(
        type: groupAnnouncementStateType,
        content: {'event_id': r'$historical-announcement'},
        senderId: '@owner:test',
        room: this,
        eventId: r'$reference',
        stateKey: '',
        originServerTs: DateTime(2026)));
  }
  Event? cached;
  @override
  Future<Event?> getEventById(String eventID) async =>
      cached ?? await super.getEventById(eventID);
  @override
  Future<List<DeviceKeys>> getUserDeviceKeys() async => [];
  @override
  Future<List<User>> requestParticipants(
          [List<Membership> membershipFilter = const [
            Membership.join,
            Membership.invite,
            Membership.knock
          ],
          bool suppressWarning = false,
          bool cache = true]) async =>
      [
        User('@member:test', membership: 'join', room: this),
        User('@owner:test', membership: 'join', room: this),
      ];
}

class _Encryption extends Encryption {
  _Encryption(Client client) : super(client: client);
  late final _keys = _Keys(this);
  @override
  _Keys get keyManager => _keys;
}

class _Keys extends KeyManager {
  _Keys(super.encryption);
  SessionKey? recovered;
  @override
  Future<bool> isCached() async => false;
  @override
  SessionKey? getInboundGroupSession(String roomId, String sessionId) =>
      recovered;
  void recover(Room room, {bool failOldIndex = false}) {
    recovered = SessionKey(
        content: {},
        inboundGroupSession: _NativeSession(failOldIndex: failOldIndex),
        key: '@member:test',
        roomId: room.id,
        sessionId: 'historical-session',
        senderKey: 'sender-key',
        senderClaimedKeys: {});
    room.onSessionKeyReceived.add('historical-session');
  }
}

class _NativeSession implements olm.InboundGroupSession {
  _NativeSession({this.failOldIndex = false});
  final bool failOldIndex;
  @override
  olm.DecryptResult decrypt(String message) {
    expect(message, 'native-ciphertext-fixture');
    if (failOldIndex) throw Exception('UNKNOWN_MESSAGE_INDEX');
    return _Result();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Result implements olm.DecryptResult {
  @override
  // Native libolm's interface uses this exact field name.
  // ignore: non_constant_identifier_names
  int message_index = 0;
  @override
  String plaintext = jsonEncode({
    'type': EventTypes.Message,
    'content': const GroupAnnouncement(
            [AnnouncementBlock.text('recovered historical announcement')])
        .toContent()
  });
}
