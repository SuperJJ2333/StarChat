import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/search/room_search_event_delta.dart';

void main() {
  test('redaction target joins event identity, including v11 content target',
      () {
    final delta = RoomSearchEventDelta();
    delta.add({
      'event_id': 'redaction',
      'redacts': 'old',
      'content': {'redacts': 'v11', 'body': 'never retained'}
    });
    expect(delta.drain().ids, ['redaction', 'old', 'v11']);
    expect(delta.drain().ids, isEmpty);
  });
  test('overflow requests authoritative replay with bounded identities', () {
    final delta = RoomSearchEventDelta(capacity: 2);
    for (var i = 0; i < 10; i++) {
      delta.add({'event_id': 'e$i'});
    }
    final result = delta.drain();
    expect(result.rescan, isTrue);
    expect(result.ids.length, lessThanOrEqualTo(2));
    expect(delta.drain().rescan, isFalse);
  });
}
