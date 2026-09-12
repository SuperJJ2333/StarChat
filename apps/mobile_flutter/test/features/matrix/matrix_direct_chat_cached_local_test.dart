import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_direct_chat_adapter.dart';
import 'package:matrix/matrix.dart';

/// Local direct-chat recovery must be able to use only already-synced Matrix
/// state. These fixtures use the actual SDK [Client] and [Room] state model;
/// the mock transport fails the test if the cache-only lookup reaches HTTP.
void main() {
  test('complete encrypted joined m.direct room opens locally without HTTP',
      () async {
    final fixture = _LocalMatrixFixture();
    final room = fixture.addRoom();

    final found = await MatrixDirectChatBackend(fixture.client)
        .findCachedJoinedDirectRoom(_peer);

    expect(found?.roomId, room.id);
    expect(found?.encrypted, isTrue);
    expect(found?.participantIds, {_self, _peer});
    expect(fixture.httpRequests, 0,
        reason: 'safe cached recovery must not use a Matrix endpoint');
  });

  test('joined self with an invited peer opens existing history locally',
      () async {
    final fixture = _LocalMatrixFixture();
    fixture.addRoom(
        joinedSummary: 1, invitedSummary: 1, peerMembership: 'invite');

    final found = await MatrixDirectChatBackend(fixture.client)
        .findCachedJoinedDirectRoom(_peer);

    expect(found?.roomId, '!cached:example.test');
    expect(fixture.httpRequests, 0);
  });

  test('cold-start lazy members hydrate from the local SDK database only',
      () async {
    final fixture = _LocalMatrixFixture(databaseBacked: true);
    fixture.addRoom(includePeer: false, storePeerInDatabase: true);

    final found = await MatrixDirectChatBackend(fixture.client)
        .findCachedJoinedDirectRoom(_peer);

    expect(found?.participantIds, {_self, _peer});
    expect(fixture.httpRequests, 0,
        reason: 'database hydration must not fall through to /members');
  });

  test('late database members cannot revive a room that was left meanwhile',
      () async {
    final heldRead = Completer<List<User>>();
    final fixture = _LocalMatrixFixture(heldDatabaseRead: heldRead);
    final room = fixture.addRoom(includePeer: false, storePeerInDatabase: true);

    final lookup = MatrixDirectChatBackend(fixture.client)
        .findCachedJoinedDirectRoom(_peer);
    await fixture.waitForDatabaseRead().timeout(const Duration(seconds: 1));
    room.membership = Membership.leave;
    heldRead.complete(fixture.storedMembers);

    expect(await lookup, isNull);
    expect(fixture.httpRequests, 0);
  });

  test('a local database read failure is inconclusive and never reaches HTTP',
      () async {
    final fixture = _LocalMatrixFixture(
        databaseBacked: true, databaseError: StateError('cache unavailable'));
    fixture.addRoom(includePeer: false);

    final found = await MatrixDirectChatBackend(fixture.client)
        .findCachedJoinedDirectRoom(_peer);

    expect(found, isNull);
    expect(fixture.httpRequests, 0);
  });

  for (final scenario in <_UnsafeRoomScenario>[
    const _UnsafeRoomScenario('lazy member snapshot',
        joinedSummary: 2, includePeer: false),
    const _UnsafeRoomScenario('partial room', partial: true),
    const _UnsafeRoomScenario('three joined members',
        joinedSummary: 3, thirdMember: true),
    const _UnsafeRoomScenario('unencrypted room', encrypted: false),
    const _UnsafeRoomScenario('unjoined invitation',
        membership: Membership.invite),
  ]) {
    test('${scenario.name} is inconclusive and never reaches HTTP', () async {
      final fixture = _LocalMatrixFixture();
      fixture.addRoom(
        membership: scenario.membership,
        joinedSummary: scenario.joinedSummary,
        partial: scenario.partial,
        encrypted: scenario.encrypted,
        includePeer: scenario.includePeer,
        thirdMember: scenario.thirdMember,
      );

      final found = await MatrixDirectChatBackend(fixture.client)
          .findCachedJoinedDirectRoom(_peer);

      expect(found, isNull,
          reason:
              'an unsafe local snapshot must defer to canonical coordination');
      expect(fixture.httpRequests, 0,
          reason: 'a local miss must not join, query members, or repair');
    });
  }
}

const _self = '@self:example.test';
const _peer = '@peer:example.test';
const _third = '@third:example.test';

final class _LocalMatrixFixture {
  _LocalMatrixFixture({
    bool databaseBacked = false,
    Completer<List<User>>? heldDatabaseRead,
    Object? databaseError,
  }) {
    final transport = MockClient((_) async {
      httpRequests++;
      throw StateError(
          'cache-only direct-chat lookup unexpectedly reached HTTP');
    });
    database = (databaseBacked || heldDatabaseRead != null)
        ? _StoredUsersDatabase(storedMembers,
            heldRead: heldDatabaseRead, error: databaseError)
        : null;
    client = database != null
        ? _DatabaseBackedClient(database!, httpClient: transport)
        : Client('cached-direct-chat-test', httpClient: transport);
    client.setUserId(_self);
  }

  late final Client client;
  int httpRequests = 0;
  final storedMembers = <User>[];
  late final _StoredUsersDatabase? database;

  Future<void> waitForDatabaseRead() => database!.readStarted.future;

  Room addRoom({
    Membership membership = Membership.join,
    int joinedSummary = 2,
    int invitedSummary = 0,
    bool partial = false,
    bool encrypted = true,
    bool includePeer = true,
    bool thirdMember = false,
    String peerMembership = 'join',
    bool storePeerInDatabase = false,
  }) {
    final room = Room(
      id: '!cached:example.test',
      client: client,
      membership: membership,
      summary: RoomSummary.fromJson({
        'm.joined_member_count': joinedSummary,
        'm.invited_member_count': invitedSummary,
      }),
    )..partial = partial;
    client.rooms.add(room);
    _setMember(room, _self, membership == Membership.invite ? 'invite' : 'join',
        isDirect: membership == Membership.invite);
    if (includePeer) _setMember(room, _peer, peerMembership);
    if (storePeerInDatabase) {
      storedMembers.add(User(_peer, membership: peerMembership, room: room));
    }
    if (thirdMember) _setMember(room, _third, 'join');
    if (encrypted) {
      _setState(room, EventTypes.Encryption,
          {'algorithm': Client.supportedGroupEncryptionAlgorithms.first});
    }
    _setDirectChatAccountData();
    return room;
  }

  void _setDirectChatAccountData() {
    client.accountData['m.direct'] = BasicEvent.fromJson({
      'type': 'm.direct',
      'content': <String, Object?>{
        _peer: <String>['!cached:example.test'],
      },
    });
  }

  void _setMember(Room room, String userId, String membership,
      {bool isDirect = false}) {
    _setState(
        room,
        EventTypes.RoomMember,
        <String, Object?>{
          'membership': membership,
          if (isDirect) 'is_direct': true,
        },
        stateKey: userId,
        sender: userId);
  }

  void _setState(Room room, String type, Map<String, Object?> content,
      {String stateKey = '', String sender = _self}) {
    room.setState(Event.fromMatrixEvent(
      MatrixEvent.fromJson({
        'type': type,
        'state_key': stateKey,
        'sender': sender,
        'event_id': '\$${type.hashCode}-$stateKey',
        'origin_server_ts': 1,
        'content': content,
      }),
      room,
    ));
  }
}

final class _DatabaseBackedClient extends Client {
  _DatabaseBackedClient(this.storedDatabase, {required http.Client httpClient})
      : super('cached-direct-chat-database-test', httpClient: httpClient);

  final _StoredUsersDatabase storedDatabase;

  @override
  DatabaseApi? get database => storedDatabase;
}

final class _StoredUsersDatabase extends Fake implements DatabaseApi {
  _StoredUsersDatabase(this.members, {this.heldRead, this.error});

  final List<User> members;
  final Completer<List<User>>? heldRead;
  final Object? error;
  final readStarted = Completer<void>();

  @override
  Future<List<User>> getUsers(Room room) async {
    if (!readStarted.isCompleted) readStarted.complete();
    if (error != null) throw error!;
    return heldRead?.future ?? members;
  }
}

final class _UnsafeRoomScenario {
  const _UnsafeRoomScenario(
    this.name, {
    this.membership = Membership.join,
    this.joinedSummary = 2,
    this.partial = false,
    this.encrypted = true,
    this.includePeer = true,
    this.thirdMember = false,
  });

  final String name;
  final Membership membership;
  final int joinedSummary;
  final bool partial;
  final bool encrypted;
  final bool includePeer;
  final bool thirdMember;
}
