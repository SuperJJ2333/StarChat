import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_direct_chat_adapter.dart';
import 'package:liuhetong_mobile/features/matrix/direct_invitation_auto_join.dart';

class InviteClient extends Fake implements Client {
  int syncWaits = 0;
  @override
  String get userID => '@self:test';
  @override
  final rooms = <Room>[];
  @override
  Map<String, dynamic> get directChats => {};
  @override
  Room? getRoomById(String id) => rooms.where((r) => r.id == id).firstOrNull;
  @override
  String? getDirectChatFromUserId(String id) => null;
  @override
  Future<SyncUpdate> waitForRoomInSync(String id,
      {bool join = false, bool invite = false, bool leave = false}) async {
    syncWaits++;
    return SyncUpdate(nextBatch: 'test');
  }
}

class InviteRoom extends Room {
  @override
  void setState(StrippedStateEvent state) {
    (states[state.type] ??= {})[state.stateKey!] = state;
  }

  InviteRoom(InviteClient client, {super.id = '!dm:test'})
      : super(client: client, membership: Membership.invite) {
    setState(User.fromState(
      stateKey: client.userID,
      senderId: '@friend:test',
      typeKey: EventTypes.RoomMember,
      content: const {'membership': 'invite', 'is_direct': true},
      room: this,
    ));
    setState(User('@friend:test', membership: 'join', room: this));
  }
  int joins = 0;
  int memberRequestsBeforeJoin = 0;
  bool secure = true;
  bool mapped = false;
  bool failJoin = false;
  Completer<void>? joinGate;
  @override
  bool get encrypted => secure;
  @override
  String? get directChatMatrixID => '@friend:test';
  @override
  Future<void> join({bool leaveIfNotFound = true}) async {
    joins++;
    if (failJoin) throw StateError('offline');
    await joinGate?.future;
    membership = Membership.join;
  }

  @override
  Future<void> addToDirectChat(String userID) async => mapped = true;
  @override
  Future<List<User>> requestParticipants([
    List<Membership> membershipFilter = const [
      Membership.join,
      Membership.invite,
      Membership.knock
    ],
    bool suppressWarning = false,
    bool cache = true,
  ]) async {
    if (membership != Membership.join) {
      memberRequestsBeforeJoin++;
      throw StateError('M_FORBIDDEN: members requires joined membership');
    }
    return getParticipants(membershipFilter);
  }
}

void main() {
  test('a timed out invitation releases its retry guard', () async {
    final client = InviteClient();
    final gate = Completer<void>();
    final room = InviteRoom(client)..joinGate = gate;
    client.rooms.add(room);
    final inFlight = <String>{};
    expect(
        await autoJoinFriendDirectInvites(
            client: client,
            friendMatrixIds: {'@friend:test'},
            inFlight: inFlight,
            operationTimeout: const Duration(milliseconds: 10)),
        isEmpty);
    expect(inFlight, isEmpty);
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(room.mapped, isFalse);
  });
  test('a slow first invitation does not block joining later friends',
      () async {
    final client = InviteClient();
    final gate = Completer<void>();
    final first = InviteRoom(client, id: '!slow:test')..joinGate = gate;
    final second = InviteRoom(client, id: '!fast:test');
    client.rooms.addAll([first, second]);
    final pending = autoJoinFriendDirectInvites(
        client: client, friendMatrixIds: {'@friend:test'}, inFlight: {});
    await Future<void>.delayed(Duration.zero);
    final joinedWhileFirstPending = second.joins;
    gate.complete();
    await pending;
    expect(joinedWhileFirstPending, 1);
  });
  test('friend DM invitation joins without requesting members while invited',
      () async {
    final client = InviteClient();
    final room = InviteRoom(client);
    client.rooms.add(room);
    final inFlight = <String>{};
    expect(
        await autoJoinFriendDirectInvites(
            client: client,
            friendMatrixIds: {'@friend:test'},
            inFlight: inFlight),
        {room.id});
    expect(room.joins, 1);
    expect(room.memberRequestsBeforeJoin, 0);
    expect(room.mapped, isTrue);
    expect(client.syncWaits, 0,
        reason:
            'join may already have synced; waiting for another update hangs');
    expect(inFlight, isEmpty);
  });

  test('unknown or unencrypted or non-two-member invites are not auto joined',
      () async {
    for (final scenario in [
      'unknown',
      'plaintext',
      'extra-member',
      'in-flight'
    ]) {
      final client = InviteClient();
      final room = InviteRoom(client);
      if (scenario == 'plaintext') room.secure = false;
      if (scenario == 'extra-member') {
        room.setState(User('@extra:test', membership: 'join', room: room));
      }
      client.rooms.add(room);
      expect(
          await autoJoinFriendDirectInvites(
              client: client,
              friendMatrixIds: scenario == 'unknown' ? {} : {'@friend:test'},
              inFlight: scenario == 'in-flight' ? {room.id} : {}),
          isEmpty);
      expect(room.joins, 0, reason: scenario);
    }
  });

  test('failed invite is retryable and does not stop other rooms', () async {
    final client = InviteClient();
    final first = InviteRoom(client, id: '!first:test')..failJoin = true;
    final second = InviteRoom(client, id: '!second:test');
    client.rooms.addAll([first, second]);
    final inFlight = <String>{};
    expect(
        await autoJoinFriendDirectInvites(
            client: client,
            friendMatrixIds: {'@friend:test'},
            inFlight: inFlight),
        {second.id});
    expect(inFlight, isEmpty);
    first.failJoin = false;
    expect(
        await autoJoinFriendDirectInvites(
            client: client,
            friendMatrixIds: {'@friend:test'},
            inFlight: inFlight),
        {first.id});
    expect(second.joins, 1);
  });
  test('opening a new friend invite joins before requesting full members',
      () async {
    final client = InviteClient();
    final room = InviteRoom(client);
    client.rooms.add(room);
    final result = await MatrixDirectChatBackend(client)
        .findJoinedDirectRoom('@friend:test');
    expect(result?.participantIds, {'@self:test', '@friend:test'});
    expect(client.syncWaits, 0,
        reason:
            'join may already have synced; waiting for another update hangs');
    expect(room.joins, 1);
    expect(room.memberRequestsBeforeJoin, 0);
    expect(room.mapped, isTrue);
  });

  test('home consumes direct invitations on sync and contact cache updates',
      () {
    final source =
        File('lib/features/matrix/matrix_home_page.dart').readAsStringSync();
    expect(source, contains('conversations.autoJoinDirectInvites('));
    final capability =
        File('lib/features/matrix/matrix_e2ee_client.dart').readAsStringSync();
    expect(capability, contains('autoJoinFriendDirectInvites('));
    final identity = source.substring(source.indexOf('void _identityChanged()'),
        source.indexOf('void didUpdateWidget'));
    expect(identity, contains('_processPendingDirectInvites()'));
  });
}
