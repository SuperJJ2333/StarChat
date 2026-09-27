import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_preferences.dart';

import '../features/matrix/matrix_client_factory_test.dart'
    show SnapshotClient, CountingSnapshotRoom;

/// Regression: unrelated activity must not invalidate a room timeline.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
      'real member values, ordering and power remain fresh without rescanning on reads',
      () async {
    final client = _SyncClient(receiptOnly: false);
    final room = _MemberRoom(client);
    client.snapshotRooms.add(room);
    room.setState(StrippedStateEvent(
        type: EventTypes.RoomMember,
        senderId: '@a:test',
        stateKey: '@a:test',
        content: {'membership': 'join', 'displayname': 'Alice'}));
    room.setState(StrippedStateEvent(
        type: EventTypes.RoomMember,
        senderId: '@b:test',
        stateKey: '@b:test',
        content: {'membership': 'join', 'displayname': 'Bob'}));
    final owner = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.example'));
    final lease = await owner.openRoomLease(room.id);
    await Future<void>.delayed(Duration.zero);
    try {
      final initial = lease.roomInfo.members;
      expect(initial.map((m) => m.displayName), containsAll(['Alice', 'Bob']));
      final reads = room.reads;
      for (var i = 0; i < 20; i++) {
        expect(identical(initial, lease.roomInfo.members), isTrue);
      }
      expect(room.reads, reads);
      room.setState(StrippedStateEvent(
          type: EventTypes.RoomMember,
          senderId: '@a:test',
          stateKey: '@a:test',
          content: {
            'membership': 'join',
            'displayname': 'Alice updated',
            'avatar_url': 'mxc://test/avatar'
          }));
      await Future<void>.delayed(Duration.zero);
      expect(
          lease.roomInfo.members
              .firstWhere((m) => m.id == '@a:test')
              .displayName,
          'Alice updated');
      expect(
          lease.roomInfo.members.firstWhere((m) => m.id == '@a:test').avatarUri,
          Uri.parse('mxc://test/avatar'));
      room.setState(StrippedStateEvent(
          type: EventTypes.RoomPowerLevels,
          senderId: '@a:test',
          stateKey: '',
          content: {
            'users': {'@a:test': 100}
          }));
      await Future<void>.delayed(Duration.zero);
      expect(
          lease.roomInfo.members
              .firstWhere((m) => m.id == '@a:test')
              .powerLevel,
          100);
      room.roomAccountData[conversationPreferenceType] =
          BasicRoomEvent(type: conversationPreferenceType, content: {
        'member_order_ids': ['@b:test', '@a:test']
      });
      expect(lease.roomInfo.members.map((m) => m.id), ['@b:test', '@a:test']);
    } finally {
      await lease.cancel();
      await client.dispose();
    }
  });

  test('member projection is reused until room member or power state changes',
      () async {
    final client = _SyncClient(receiptOnly: false);
    final room = _LocalTimelineRoom(client);
    client.snapshotRooms.add(room);
    final owner = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.example'));
    final lease = await owner.openRoomLease(room.id);
    try {
      final first = lease.roomInfo;
      final reads = room.participantReads;
      expect(identical(first.members, lease.roomInfo.members), isTrue);
      expect(room.participantReads, reads);
      room.setState(StrippedStateEvent(
          senderId: '@me:test',
          type: EventTypes.RoomMember,
          stateKey: '@other:test',
          content: {'membership': 'join'}));
      await Future<void>.delayed(Duration.zero);
      final changed = lease.roomInfo;
      expect(identical(first.members, changed.members), isFalse);
      final changedReads = room.participantReads;
      expect(identical(changed.members, lease.roomInfo.members), isTrue);
      expect(room.participantReads, changedReads);
      room.setState(StrippedStateEvent(
          senderId: '@me:test',
          type: EventTypes.RoomPowerLevels,
          stateKey: '',
          content: {
            'users': {'@other:test': 100}
          }));
      await Future<void>.delayed(Duration.zero);
      expect(identical(changed.members, lease.roomInfo.members), isFalse);
    } finally {
      await lease.cancel();
      await client.dispose();
    }
  });
  test(
      'current room state and decrypted events notify, disposal removes listeners',
      () async {
    final client = _SyncClient(receiptOnly: false);
    final room = _LocalTimelineRoom(client);
    client.snapshotRooms.add(room);
    final owner = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.example'));
    final lease = await owner.openRoomLease(room.id);
    var updates = 0;
    final timeline =
        await lease.openLogicalRoomTimeline(onUpdate: () => updates++);
    try {
      final initial = updates;
      client.onEvent.add(EventUpdate(
          roomID: room.id,
          type: EventUpdateType.timeline,
          content: {
            'event_id': r'$live',
            'sender': '@me:test',
            'origin_server_ts': 1,
            'type': EventTypes.Message,
            'content': {'msgtype': 'm.text', 'body': 'live'}
          }));
      await Future<void>.delayed(Duration.zero);
      expect(updates, greaterThan(initial));
      expect(
          timeline.snapshot().map((message) => message.id), contains(r'$live'));
      final before = updates;
      room.setState(StrippedStateEvent(
          senderId: '@me:test',
          type: EventTypes.RoomMember,
          stateKey: '@other:test',
          content: {'membership': 'join'}));
      await Future<void>.delayed(Duration.zero);
      expect(updates, greaterThan(before));
      final beforePreference = updates;
      client.onEvent.add(EventUpdate(
          roomID: room.id,
          type: EventUpdateType.accountData,
          content: {
            'type': conversationPreferenceType,
            'content': {
              'member_order_ids': ['@b:test', '@a:test']
            }
          }));
      await Future<void>.delayed(Duration.zero);
      expect(updates, greaterThan(beforePreference),
          reason: 'cross-device room preferences must update open room');
      final afterPreference = updates;
      client.onEvent.add(EventUpdate(
          roomID: '!unrelated:test',
          type: EventUpdateType.accountData,
          content: {
            'type': conversationPreferenceType,
            'content': {
              'member_order_ids': ['@b:test']
            }
          }));
      await Future<void>.delayed(Duration.zero);
      expect(updates, afterPreference);
      final afterMember = updates;
      client.onEvent.add(EventUpdate(
          roomID: room.id,
          type: EventUpdateType.decryptedTimelineQueue,
          content: {
            'event_id': r'$decrypted',
            'type': EventTypes.Message,
            'content': {'msgtype': 'm.text', 'body': 'fixture'}
          }));
      await Future<void>.delayed(Duration.zero);
      expect(updates, greaterThan(afterMember));
      timeline.dispose();
      final disposed = updates;
      room.setState(StrippedStateEvent(
          senderId: '@me:test',
          type: EventTypes.RoomName,
          stateKey: '',
          content: {'name': 'Changed'}));
      await Future<void>.delayed(Duration.zero);
      expect(updates, disposed);
    } finally {
      timeline.dispose();
      await lease.cancel();
      await client.dispose();
    }
  });

  for (final receiptOnly in [false, true]) {
    test(
        'scoped: ${receiptOnly ? "receipt-only" : "unrelated-room"} sync '
        'leaves unchanged logical timeline alone', () async {
      final client = _SyncClient(receiptOnly: receiptOnly);
      final room = _LocalTimelineRoom(client);
      client.snapshotRooms.add(room);
      final owner = MatrixSdkE2eeClient(client,
          homeserver: Uri.parse('https://matrix.example'));
      final lease = await owner.openRoomLease(room.id);
      var logicalUpdates = 0;
      Completer<void>? nextUpdate;
      final timeline = await lease.openLogicalRoomTimeline(onUpdate: () {
        logicalUpdates++;
        final pending = nextUpdate;
        if (pending != null && !pending.isCompleted) pending.complete();
      });
      try {
        expect(logicalUpdates, 1, reason: 'initial source attachment callback');
        expect(room.sdkUpdates, 0);
        expect(timeline.snapshot(), isEmpty);
        nextUpdate = Completer<void>();
        await owner.syncIfActive();
        await Future<void>.delayed(Duration.zero);
        expect(client.syncCalls, 1);
        expect(room.sdkUpdates, 0,
            reason: 'the real SDK Timeline ignored unrelated/ephemeral data');
        expect(logicalUpdates, 1, reason: 'unchanged sources must not notify');
        expect(timeline.snapshot(), isEmpty,
            reason: 'no current-room timeline data changed');
        if (!receiptOnly) {
          nextUpdate = Completer<void>();
          client.onEvent.add(EventUpdate(
              roomID: '!unrelated:test',
              type: EventUpdateType.timeline,
              content: {
                'event_id': r'$unrelated-message',
                'type': EventTypes.Message,
                'sender': '@other:test',
                'content': {'msgtype': 'm.text', 'body': 'diagnostic'},
              }));
          await Future<void>.delayed(Duration.zero);
          expect(room.sdkUpdates, 0);
          expect(logicalUpdates, 1,
              reason:
                  'unrelated room events must not invalidate this timeline');
          expect(client.syncCalls, 1,
              reason: 'the extra callback did not require another sync call');
        }
      } finally {
        timeline.dispose();
        await lease.cancel();
        await client.dispose();
      }
    });
  }
}

final class _SyncClient extends SnapshotClient {
  _SyncClient({required this.receiptOnly});
  final bool receiptOnly;

  @override
  Future<SyncUpdate> sync(
      {String? filter,
      String? since,
      bool? fullState,
      PresenceType? setPresence,
      int? timeout}) async {
    syncCalls++;
    final roomId = receiptOnly ? '!current:test' : '!unrelated:test';
    final receipt = <String, dynamic>{
      'type': 'm.receipt',
      'content': {
        r'$other': {
          'm.read': {
            '@other:test': {'ts': 1}
          }
        }
      },
    };
    if (receiptOnly) {
      onEvent.add(EventUpdate(
          roomID: roomId, type: EventUpdateType.ephemeral, content: receipt));
    }
    final update = SyncUpdate.fromJson({
      'next_batch': 'diagnostic-next',
      'rooms': {
        'join': {
          roomId: receiptOnly
              ? {
                  'ephemeral': {
                    'events': [receipt]
                  }
                }
              : {
                  'timeline': {'events': [], 'limited': false}
                }
        }
      },
    });
    onSync.add(update);
    return update;
  }
}

final class _LocalTimelineRoom extends CountingSnapshotRoom {
  _LocalTimelineRoom(Client client)
      : super(id: '!current:test', client: client, joined: true);
  int sdkUpdates = 0;

  @override
  Future<Timeline> getTimeline(
          {void Function(int)? onChange,
          void Function(int)? onRemove,
          void Function(int)? onInsert,
          void Function()? onNewEvent,
          void Function()? onUpdate,
          String? eventContextId}) async =>
      Timeline(
        room: this,
        chunk: TimelineChunk(events: [], prevBatch: ''),
        onUpdate: () {
          sdkUpdates++;
          onUpdate?.call();
        },
      );
}

final class _MemberRoom extends Room {
  _MemberRoom(Client client)
      : super(id: '!members:test', client: client, membership: Membership.join);
  int reads = 0;
  @override
  List<User> getParticipants(
      [List<Membership> membershipFilter = const [
        Membership.join,
        Membership.invite,
        Membership.knock
      ]]) {
    reads++;
    return super.getParticipants(membershipFilter);
  }
}
