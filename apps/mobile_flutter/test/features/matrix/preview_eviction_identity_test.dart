import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';

import 'matrix_client_factory_test.dart' show SnapshotClient;
import 'direct_room_identity_integration_test.dart' show IdentityFlowRoom;

class _CountStore extends Fake implements DatabaseApi {
  final ids = <String, List<String>>{};
  String? heldRoom;
  Completer<int>? heldRead;
  Completer<void>? entered;
  @override
  Future<int> getTimelineEventCount(Room room) async {
    if (room.id == heldRoom && heldRead != null) {
      final read = heldRead!;
      heldRead = null;
      entered!.complete();
      return read.future;
    }
    return ids[room.id]?.length ?? 0;
  }

  @override
  Future<List<String>> getEventIdList(Room room,
          {int start = 0, bool includeSending = false, int? limit}) =>
      throw StateError('Count lookup must not enumerate whole room IDs');
}

class _CountClient extends SnapshotClient {
  final store = _CountStore();
  final directory = <String, dynamic>{};
  @override
  DatabaseApi get database => store;
  @override
  Map<String, dynamic> get directChats => directory;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('preview eviction never changes the room with most stored history',
      () async {
    SharedPreferences.setMockInitialValues({});
    final client = _CountClient();
    final old = IdentityFlowRoom(
        client: client, id: '!z-old:test', membership: Membership.join);
    final newer = IdentityFlowRoom(
        client: client, id: '!a-new:test', membership: Membership.join);
    client.snapshotRooms.addAll([old, newer]);
    client.directory['@peer:test'] = [old.id, newer.id];
    client.store.ids[old.id] = List.generate(100, (i) => '\$old-$i');
    client.store.ids[newer.id] = List.generate(33, (i) => '\$new-$i');
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://test'), suspendClient: (_) async {});
    await matrix.conversations.snapshot();
    try {
      for (final room in [old, newer]) {
        for (final id in client.store.ids[room.id]!) {
          final content = {
            'event_id': id,
            'type': EventTypes.Message,
            'sender': '@peer:test',
            'origin_server_ts': room == old ? 1 : 2,
            'content': {'msgtype': 'm.text', 'body': 'synthetic'}
          };
          room.lastEvent = Event.fromJson(content, room);
          client.onEvent.add(EventUpdate(
              roomID: room.id,
              type: EventUpdateType.decryptedTimelineQueue,
              content: content));
        }
      }
      await Future<void>.delayed(Duration.zero);
      expect((await matrix.conversations.snapshot()).rooms.single.id, old.id);
      expect(matrix.logicalPrimaryRoomIdSync(newer.id), old.id);
      void history(String id) => client.onEvent.add(EventUpdate(
              roomID: old.id,
              type: EventUpdateType.history,
              content: {
                'event_id': id,
                'type': EventTypes.Message,
                'sender': '@peer:test',
                'origin_server_ts': -1,
                'content': {'msgtype': 'm.text', 'body': 'synthetic history'}
              }));
      client.store.ids[old.id] = List.generate(20, (i) => '\$small-$i');
      history('\$resize');
      await Future<void>.delayed(Duration.zero);
      expect((await matrix.conversations.snapshot()).rooms.single.id, newer.id);
      final staleRead = Completer<int>();
      client.store
        ..heldRoom = old.id
        ..heldRead = staleRead
        ..entered = Completer<void>();
      history('\$first-history');
      await Future<void>.delayed(Duration.zero);
      final snapshot = matrix.conversations.snapshot();
      await client.store.entered!.future;
      client.store.ids[old.id] = List.generate(120, (i) => '\$expanded-$i');
      history('\$second-history');
      await Future<void>.delayed(Duration.zero);
      staleRead.complete(20);
      expect((await snapshot).rooms.single.id, old.id,
          reason:
              'a stale count read cannot undo same-head history invalidation');
      expect(matrix.logicalPrimaryRoomIdSync(newer.id), old.id);
      for (var i = 0; i < 1100; i++) {
        client.onEvent.add(EventUpdate(
            roomID: '!unrelated-$i:test',
            type: EventUpdateType.decryptedTimelineQueue,
            content: {
              'event_id': '\$other-$i',
              'type': EventTypes.Message,
              'sender': '@peer:test',
              'origin_server_ts': i,
              'content': {'msgtype': 'm.text', 'body': 'synthetic'}
            }));
      }
      await Future<void>.delayed(Duration.zero);
      expect((await matrix.conversations.snapshot()).rooms.single.id, old.id);
      expect(matrix.logicalPrimaryRoomIdSync(newer.id), old.id);
    } finally {
      await matrix.suspend();
      await client.dispose();
    }
  });
}
