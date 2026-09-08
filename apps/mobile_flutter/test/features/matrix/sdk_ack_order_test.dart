import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';

void main() {
  for (final lateStatus in [
    EventStatus.sent,
    EventStatus.sending,
    EventStatus.error
  ]) {
    test('synced event cannot be overwritten by late $lateStatus echo',
        () async {
      final client = Client('ack-race');
      final room = Room(id: '!test:example', client: client);
      final timeline = Timeline(room: room, chunk: TimelineChunk(events: []));
      final serverTime = DateTime.utc(2026, 9, 7, 10);
      Map<String, dynamic> event(
              EventStatus status, DateTime at, String body) =>
          {
            'type': EventTypes.Message,
            'event_id': r'$sent',
            'sender': '@me:example',
            'origin_server_ts': at.millisecondsSinceEpoch,
            'status': status.intValue,
            'content': {'msgtype': 'm.text', 'body': body},
            'unsigned': {'transaction_id': 'tx'},
          };
      client.onEvent.add(EventUpdate(
          roomID: room.id,
          type: EventUpdateType.timeline,
          content: event(EventStatus.synced, serverTime, 'server')));
      await Future<void>.delayed(Duration.zero);
      expect(timeline.events.single.originServerTs.toUtc(), serverTime);
      client.onEvent.add(EventUpdate(
          roomID: room.id,
          type: EventUpdateType.timeline,
          content: event(lateStatus,
              serverTime.subtract(const Duration(minutes: 2)), 'local')));
      await Future<void>.delayed(Duration.zero);
      expect(timeline.events.single.status, EventStatus.synced);
      expect(timeline.events.single.originServerTs.toUtc(), serverTime);
      expect(timeline.events.single.body, 'server');
      // Another authoritative sync (e.g. redaction/decryption) still applies.
      client.onEvent.add(EventUpdate(
          roomID: room.id,
          type: EventUpdateType.timeline,
          content: event(EventStatus.synced, serverTime, 'updated')));
      await Future<void>.delayed(Duration.zero);
      expect(timeline.events.single.body, 'updated');
      timeline.cancelSubscriptions();
      await client.dispose();
    });
  }
}
