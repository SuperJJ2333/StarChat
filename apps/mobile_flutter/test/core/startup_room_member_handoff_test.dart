import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/core/startup_projection/startup_projection.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_store_test.dart' show MemorySecureKeyValueStore;
import '../features/matrix/matrix_client_factory_test.dart'
    show LogoutTrackingClient;

class _Room extends Room {
  _Room(Client client)
      : super(
            id: '!group:synthetic.test',
            client: client,
            membership: Membership.join);
  Future<void> Function()? refresh;
  @override
  Future<List<User>> requestParticipants(
      [List<Membership> membershipFilter = const [Membership.join],
      bool suppressWarning = false,
      bool cache = true]) async {
    await refresh?.call();
    return getParticipants(membershipFilter);
  }
}

void member(Room room, String id, String name, {String? avatar}) {
  room.setState(Event(
      room: room,
      eventId: 'state-$id-$name',
      senderId: id,
      originServerTs: DateTime.utc(2026),
      type: EventTypes.RoomMember,
      stateKey: id,
      content: {
        'membership': 'join',
        'displayname': name,
        if (avatar != null) 'avatar_url': avatar
      }));
}

Future<MatrixClientContinuityMetadata> continuity(Client client) async =>
    MatrixClientContinuityMetadata(
        isLoggedIn: true,
        userId: client.userID,
        deviceId: client.deviceID,
        ed25519Fingerprint: 'synthetic',
        databaseGeneration: 'synthetic');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final pending in [false, true]) {
    test('member metadata hands off to canonical state (pending=$pending)',
        () async {
      final client = LogoutTrackingClient('metadata',
          loggedIn: !pending,
          matrixUserId: '@self:synthetic.test',
          matrixDeviceId: 'DEVICE');
      final room = _Room(client);
      client.roomOverride = room;
      final full = Completer<void>();
      if (pending) client.seedStartupRooms([room], full.future);
      client.loggedIn = true;
      member(room, client.userID!, 'Self');
      member(room, '@other:synthetic.test', 'Canonical member',
          avatar: 'mxc://synthetic.test/canonical');
      final epoch = base64Url.encode(List.filled(32, 1)).replaceAll('=', '');
      final owner = MatrixSdkE2eeClient(client,
          readContinuityMetadata: continuity,
          homeserver: Uri.parse('https://synthetic.test'),
          secureSessionStore: SecureSessionStore(MemorySecureKeyValueStore()),
          startupProjection: StartupProjection([
            StartupProjectionRoom(
                id: room.id,
                name: 'Cached group',
                direct: false,
                peer: null,
                unread: 0,
                pinned: false,
                muted: false,
                canSend: true,
                activity: 0,
                events: [],
                members: const [
                  StartupProjectionMember(
                      id: '@other:synthetic.test',
                      name: 'Cached member',
                      avatar: 'mxc://synthetic.test/cached')
                ])
          ]),
          startupAdmission: StartupProjectionAdmission(
              scope: '',
              homeserver: 'https://synthetic.test',
              userId: client.userID!,
              deviceId: 'DEVICE',
              fingerprint: 'synthetic',
              databaseGeneration: 'synthetic',
              installationId: epoch,
              epoch: epoch,
              databaseKey: base64Url.encode(List.filled(32, 2)),
              registrationKey: 'synthetic'));
      final lease = await owner.openRoomLease(room.id);
      try {
        expect(owner.hasCachedRoomDisplay(room.id), isTrue);
        if (pending) {
          final cached = lease.roomInfo;
          expect(cached.members.single.displayName, 'Cached member');
          expect(cached.members.single.avatarUri,
              Uri.parse('mxc://synthetic.test/cached'));
          expect(cached.members.single.isJoined, isFalse,
              reason: 'bounded display members are not membership authority');
          expect(cached.members.single.powerLevel, 0);
          expect(cached.canMentionAll, isFalse);
          expect(lease.canQueueLocalText, isTrue);
          full.complete();
          await client.initializationCompleted;
        }
        final canonical = lease.roomInfo;
        expect(canonical.members.where((m) => m.isJoined).length, 2);
        expect(
            canonical.members
                .singleWhere((m) => m.id.startsWith('@other'))
                .avatarUri,
            Uri.parse('mxc://synthetic.test/canonical'));
        expect(owner.hasCachedRoomDisplay(room.id), isTrue,
            reason: 'metadata handoff must preserve the cached timeline');
      } finally {
        if (!full.isCompleted) full.complete();
        await lease.cancel();
        owner.outgoingWork.dispose();
        await client.dispose();
      }
    });
  }

  test('refresh publishes changed canonical members immediately', () async {
    final client = LogoutTrackingClient('refresh',
        loggedIn: true,
        matrixUserId: '@self:synthetic.test',
        matrixDeviceId: 'DEVICE');
    final room = _Room(client);
    client.roomOverride = room;
    member(room, '@other:synthetic.test', 'Before',
        avatar: 'mxc://synthetic.test/old');
    final owner = MatrixSdkE2eeClient(client,
        readContinuityMetadata: continuity,
        homeserver: Uri.parse('https://synthetic.test'));
    final lease = await owner.openRoomLease(room.id);
    try {
      expect(lease.roomInfo.members.single.displayName, 'Before');
      room.refresh = () async {
        // Contract: refresh must invalidate its own projection without waiting
        // for a separately delivered state notification.
        room.states[EventTypes.RoomMember]!.clear();
        final event = Event(
            room: room,
            eventId: 'updated',
            senderId: '@new:synthetic.test',
            originServerTs: DateTime.utc(2026),
            type: EventTypes.RoomMember,
            stateKey: '@new:synthetic.test',
            content: {'membership': 'join', 'displayname': 'After'});
        room.states[EventTypes.RoomMember]![event.stateKey!] = event;
      };
      final updated = await lease.refreshRoomInfo();
      expect(updated.members.single.id, '@new:synthetic.test');
      expect(updated.members.single.displayName, 'After');
      expect(updated.members.single.avatarUri, isNull);
    } finally {
      await lease.cancel();
      owner.outgoingWork.dispose();
      await client.dispose();
    }
  });

  for (final cancel in [false, true]) {
    test(
        'late member refresh rejects ${cancel ? 'canceled' : 'replaced'} lease',
        () async {
      final client = LogoutTrackingClient('late',
          loggedIn: true,
          matrixUserId: '@self:synthetic.test',
          matrixDeviceId: 'DEVICE');
      final room = _Room(client);
      client.roomOverride = room;
      final owner = MatrixSdkE2eeClient(client,
          readContinuityMetadata: continuity,
          homeserver: Uri.parse('https://synthetic.test'));
      final lease = await owner.openRoomLease(room.id);
      final entered = Completer<void>();
      final release = Completer<void>();
      room.refresh = () async {
        entered.complete();
        await release.future;
      };
      final refresh = lease.refreshRoomInfo();
      final assertion = expectLater(refresh, throwsStateError);
      await entered.future;
      if (cancel) {
        await lease.cancel();
      } else {
        client.roomOverride = _Room(client);
      }
      release.complete();
      try {
        await assertion;
      } finally {
        await lease.cancel();
        owner.outgoingWork.dispose();
        await client.dispose();
      }
    });
  }
}
