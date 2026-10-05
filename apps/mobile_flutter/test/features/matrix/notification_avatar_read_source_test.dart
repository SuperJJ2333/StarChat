import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/core/notification/notification_coordinator.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_notification_event_source.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_read_state.dart';

class _Client extends Client {
  _Client() : super('notification-avatar-read');
  @override
  String get userID => '@me:example.test';
  @override
  Uri get homeserver => Uri.parse('https://example.test');
  @override
  String get accessToken => 'local-test-token';
}

class _Room extends Room {
  _Room(Client client, this.direct)
      : super(id: '!room:example.test', client: client);
  final bool direct;
  @override
  bool get isDirectChat => direct;
  @override
  Uri? get avatar => Uri.parse('mxc://example.test/group');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final direct in [true, false]) {
    test('direct=$direct uses conversation avatar with local auth', () async {
      final reads = ConversationReadState.shared()..resetForTest();
      reads.bindAccount('@me:example.test');
      final client = _Client();
      final room = _Room(client, direct);
      room.setState(User('@peer:example.test',
          room: room,
          displayName: 'Peer',
          avatarUrl: 'mxc://example.test/friend',
          membership: 'join'));
      client.rooms.add(room);
      final now = DateTime(2026, 10, 5, 12);
      final source = MatrixNotificationEventSource(
          client: client, readState: reads, now: () => now);
      final events = <IncomingNotification>[];
      final subscription = source.events.listen(events.add);
      await source.start();
      client.onSync.add(SyncUpdate.fromJson({'next_batch': 'initial'}));
      await Future<void>.delayed(Duration.zero);
      reads.setRoomOpen(room.id, open: true);
      reads.markCleared(room.id, eventId: 'old');
      reads.setRoomOpen(room.id, open: false);
      room.roomAccountData['m.fully_read'] = BasicRoomEvent.fromJson({
        'type': 'm.fully_read',
        'content': {'event_id': 'old'}
      });
      client.onSync.add(SyncUpdate.fromJson({
        'next_batch': 'next',
        'rooms': {
          'join': {
            room.id: {
              'timeline': {
                'events': [
                  {
                    'event_id': 'old',
                    'sender': '@peer:example.test',
                    'origin_server_ts': now.millisecondsSinceEpoch,
                    'type': 'm.room.message',
                    'content': {'msgtype': 'm.text', 'body': 'already viewed'}
                  },
                  {
                    'event_id': 'new',
                    'sender': '@peer:example.test',
                    'origin_server_ts': now.millisecondsSinceEpoch,
                    'type': 'm.room.message',
                    'content': {'msgtype': 'm.text', 'body': 'hello'}
                  }
                ]
              }
            }
          }
        }
      }));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events, hasLength(1));
      expect(events.single.event.eventId, 'new');
      expect(reads.wasViewed(room.id, 'new'), isFalse);
      expect(events.single.event.avatarUrl,
          contains(direct ? '/friend?' : '/group?'));
      expect(
          events.single.event.avatarUrl, isNot(contains('local-test-token')));
      expect(events.single.event.avatarHeaders,
          {'authorization': 'Bearer local-test-token'});
      expect(events.single.event.avatarSeed,
          contains(Uri.encodeComponent('@me:example.test')));
      await source.stop();
      await subscription.cancel();
      await client.dispose();
      reads.resetForTest();
    });
  }
}
