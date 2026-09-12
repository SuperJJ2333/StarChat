import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';

void main() {
  Timeline fragmentedTimeline({required String prevBatch, String? roomToken}) {
    final client = Client('fragment-history-fixture');
    final room = Room(id: '!fragment:synthetic', client: client)
      ..prev_batch = roomToken;
    return Timeline(
      room: room,
      chunk: TimelineChunk(
        prevBatch: prevBatch,
        events: [
          Event.fromJson(
              {
                'event_id': r'$fragment-event',
                'type': EventTypes.Message,
                'sender': '@sender:synthetic',
                'origin_server_ts': 1,
                'content': {'msgtype': 'm.text', 'body': 'synthetic'},
              },
              room),
        ],
      ),
    )..isFragmentedTimeline = true;
  }

  test('fragment history availability uses its own backward token', () async {
    final exhausted = fragmentedTimeline(prevBatch: '', roomToken: 'live-old');
    final available = fragmentedTimeline(prevBatch: 'context-old');
    expect(exhausted.canRequestHistory, isFalse);
    expect(available.canRequestHistory, isTrue);
    await exhausted.room.client.dispose();
    await available.room.client.dispose();
  });
}
