import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/decrypted_preview_cache.dart';

void main() {
  test('room bursts and many rooms have independent total limits', () {
    final cache = DecryptedPreviewCache();
    for (var room = 0; room < 100; room++) {
      for (var event = 0; event < 100; event++) {
        cache[('account', 'room-$room', 'event-$event')] = {
          'body': 'synthetic'
        };
      }
    }
    expect(cache.length, 1024);
    expect(cache.keys.where((key) => key.$2 == 'room-99'), hasLength(32));
    expect(cache[('account', 'room-99', 'event-99')], isNotNull);
    expect(cache.retainedWeight, lessThanOrEqualTo(cache.maximumWeight));
  });

  test('weight limit bounds large content and rejects an oversized copy', () {
    final cache = DecryptedPreviewCache(maximumWeight: 2000);
    final body = List.filled(300, 'x').join();
    for (var i = 0; i < 100; i++) {
      cache[('account', 'room', '$i')] = {
        'content': {'body': body}
      };
      expect(cache.retainedWeight, lessThanOrEqualTo(2000));
    }
    expect(cache.length, lessThan(3));
    cache[('account', 'room', 'oversized')] = {
      'body': List.filled(2000, 'x').join()
    };
    expect(cache[('account', 'room', 'oversized')], isNull);
    expect(cache[('account', 'room', '99')], isNotNull);
  });

  test('replacement, room removal and clear release accounted content', () {
    final cache = DecryptedPreviewCache();
    cache[('a', 'room', 'event')] = {'body': 'first'};
    cache[('a', 'room', 'event')] = {'body': 'next'};
    cache[('b', 'room', 'event')] = {'body': 'other account'};
    expect(cache.length, 2);
    cache.removeWhere((key, _) => key.$1 == 'a');
    expect(cache.keys.single.$1, 'b');
    cache.clear();
    expect(cache.length, 0);
    expect(cache.retainedWeight, 0);
  });
}
