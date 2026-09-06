import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/core/notification/notification_coordinator.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_notification_event_source.dart';

class _Client extends Client {
  _Client() : super('notification-call-filter');
  @override
  String get userID => '@me:example.test';
}

void main() {
  for (final decryptedType in [
    'm.call.invite',
    'm.room.message',
    'm.room.encrypted'
  ]) {
    test('encrypted $decryptedType follows locally resolved notification type',
        () async {
      final client = _Client();
      final now = DateTime(2026, 9, 5, 12);
      final room = Room(id: '!room:example.test', client: client);
      room.setState(User('@peer:example.test',
          room: room, displayName: 'Peer', membership: 'join'));
      client.rooms.add(room);
      final event = {
        'event_id': r'$event',
        'sender': '@peer:example.test',
        'origin_server_ts': now.millisecondsSinceEpoch,
        'type': 'm.room.encrypted',
        'content': <String, Object>{},
      };
      room.lastEvent = Event.fromJson({
        ...event,
        'type': decryptedType,
        'content': {'msgtype': 'm.text', 'body': 'hello'}
      }, room);
      final source =
          MatrixNotificationEventSource(client: client, now: () => now);
      final notifications = <IncomingNotification>[];
      final subscription = source.events.listen(notifications.add);
      await source.start();
      client.onSync.add(SyncUpdate.fromJson({'next_batch': 'initial'}));
      await Future<void>.delayed(Duration.zero);
      client.onSync.add(SyncUpdate.fromJson({
        'next_batch': 'new',
        'rooms': {
          'join': {
            room.id: {
              'timeline': {
                'events': [event]
              }
            }
          }
        }
      }));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
          notifications, hasLength(decryptedType == 'm.call.invite' ? 0 : 1));
      await source.stop();
      await subscription.cancel();
      await client.dispose();
    });
  }
}
