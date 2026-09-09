import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/local_hidden_events.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/room_mention_store.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'matrix_client_factory_test.dart' show SnapshotClient, SnapshotRoom;

class LocalDeleteRoom extends SnapshotRoom {
  LocalDeleteRoom({required super.id, required super.client})
      : super(joined: true);
  int leaves = 0;
  int forgets = 0;
  String? readThrough;
  int unread = 5;
  bool failRead = false;
  @override
  int get notificationCount => unread;
  @override
  Future<void> setReadMarker(String? eventId,
      {String? mRead, bool? public}) async {
    if (failRead) throw StateError('receipt failed');
    expect(public, isFalse);
    expect(mRead, eventId);
    readThrough = eventId;
    unread = 0;
  }

  @override
  Future<void> leave() async {
    leaves++;
  }

  @override
  Future<void> forget() async {
    forgets++;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
      'deleting a conversation preserves membership, hides history and restores on new message',
      () async {
    final client = SnapshotClient();
    final room = LocalDeleteRoom(id: '!room:test', client: client);
    Event message(String id, DateTime at) => Event(
          room: room,
          type: EventTypes.Message,
          eventId: id,
          senderId: '@peer:test',
          originServerTs: at,
          content: {
            'msgtype': MessageTypes.Text,
            'body': 'fixture',
            'm.mentions': {
              'user_ids': [client.userID!]
            }
          },
        );
    room.snapshotEvent = message('old', DateTime.utc(2026));
    client.snapshotRooms.add(room);
    final matrix =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
    await RoomMentionStore.shared.ingest(room, [room.snapshotEvent!]);
    expect(RoomMentionStore.shared.hasPending(room), isTrue);
    await matrix.conversations
        .mutate(room.id, MatrixConversationMutation.delete);
    expect(room.leaves, 0);
    expect(room.forgets, 0);
    expect(room.readThrough, 'old');
    expect(RoomMentionStore.shared.hasPending(room), isFalse);
    final deleted = (await matrix.conversations.snapshot()).rooms.single;
    expect(deleted.preference.hidden, isTrue);
    expect(deleted.lastEvent, isNull);
    expect(deleted.notificationCount, 0);
    final store = SharedPreferencesLocalHiddenEvents(
      preferences: await SharedPreferences.getInstance(),
      accountId: client.userID!,
    );
    final cutoff = store.clearedThrough(room.id)!;
    expect(
        store.isEventHidden(room.id, 'backfill',
            eventTimestamp: DateTime.utc(2025)),
        isTrue);
    final restarted =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
    expect(
        (await restarted.conversations.snapshot())
            .rooms
            .single
            .preference
            .hidden,
        isTrue);
    room.snapshotEvent = message('new', cutoff.add(const Duration(seconds: 1)));
    room.unread++;
    final restored = (await restarted.conversations.snapshot()).rooms.single;
    expect(restored.preference.hidden, isFalse);
    expect(restored.lastEvent!.eventId, 'new');
    expect(restored.notificationCount, 1);
    expect(await restarted.conversations.totalUnreadCount(), 1);
    final mentions = RoomMentionStore();
    await mentions.ingest(room, [
      room.snapshotEvent!,
      message('old', DateTime.utc(2026)),
      message('unloaded-old', DateTime.utc(2025))
    ]);
    expect((await mentions.open(room)).pendingEventIdsNewestFirst(), ['new']);
  });

  test(
      'failed read receipt preserves local history and surfaces delete failure',
      () async {
    final client = SnapshotClient();
    final room = LocalDeleteRoom(id: '!receipt-failure:test', client: client)
      ..failRead = true;
    room.snapshotEvent = Event(
        room: room,
        type: EventTypes.Message,
        eventId: 'old',
        senderId: '@peer:test',
        originServerTs: DateTime.utc(2026),
        content: {'msgtype': MessageTypes.Text, 'body': 'fixture'});
    client.snapshotRooms.add(room);
    final matrix =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
    await expectLater(
        matrix.conversations.mutate(room.id, MatrixConversationMutation.delete),
        throwsStateError);
    final snapshot = (await matrix.conversations.snapshot()).rooms.single;
    expect(snapshot.lastEvent!.eventId, 'old');
    expect(snapshot.preference.hidden, isFalse);
  });
}
