import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_direct_chat_adapter.dart';

void main() {
  test('canonical invite already synced before join response opens immediately',
      () async {
    final client = _Client();
    final room = _Room(client, Membership.invite);
    client.room = room;
    final result =
        await MatrixDirectChatBackend(client).openCanonicalRoom(room.id);
    expect(result.roomId, room.id);
    expect(client.joins, 1);
    expect(client.syncWaits, 0);
  });

  test('canonical room missing locally is joined by its known ID', () async {
    final client = _Client();
    final result =
        await MatrixDirectChatBackend(client).openCanonicalRoom('!dm:test');
    expect(result.roomId, '!dm:test');
    expect(client.joins, 1);
    expect(client.syncWaits, 0);
  });

  test('repairing m.direct does not wait for an unrelated room event',
      () async {
    final client = _Client()..mapped = false;
    client.room = _Room(client, Membership.join);
    await MatrixDirectChatBackend(client).openCanonicalRoom('!dm:test');
    expect(client.mapped, isTrue);
    expect(client.syncWaits, 0);
    expect(client.joins, 0);
  });
}

class _Client extends Fake implements Client {
  _Room? room;
  int joins = 0;
  int syncWaits = 0;
  bool mapped = true;
  @override
  String get userID => '@self:test';
  @override
  Room? getRoomById(String id) => room;
  @override
  Map<String, dynamic> get directChats => {};
  @override
  Future<void> setAccountData(
      String userId, String type, Map<String, Object?> content) async {
    mapped = true;
  }

  @override
  Future<String> joinRoomById(String roomId,
      {String? reason, ThirdPartySigned? thirdPartySigned}) async {
    joins++;
    room = _Room(this, Membership.join);
    return roomId;
  }

  @override
  Future<SyncUpdate> waitForRoomInSync(String roomId,
      {bool join = false, bool invite = false, bool leave = false}) async {
    syncWaits++;
    throw TimeoutException('No further room event follows the completed join');
  }
}

class _Room extends Room {
  _Room(_Client client, Membership membership)
      : super(id: '!dm:test', client: client, membership: membership);
  @override
  bool get encrypted => true;
  @override
  bool get isDirectChat => (client as _Client).mapped;
  @override
  String? get directChatMatrixID => isDirectChat ? '@friend:test' : null;
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
        User('@self:test', membership: 'join', room: this),
        User('@friend:test', membership: 'join', room: this),
      ];
}
