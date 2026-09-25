import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/matrix/matrix_client_factory_test.dart'
    show SnapshotClient, CountingSnapshotRoom;

/// Regression converted from the recorded pre-fix diagnostic.
/// Original failing behavior is preserved in the audit evidence logs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final receiptOnly in [false, true]) {
    test(
        'diagnostic: ${receiptOnly ? "receipt-only" : "unrelated-room"} sync '
        'does not notify unchanged logical timeline', () async {
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
        expect(logicalUpdates, 1, reason: 'unchanged sources do not publish');
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
              reason: 'unrelated room events do not refresh the current room');
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
