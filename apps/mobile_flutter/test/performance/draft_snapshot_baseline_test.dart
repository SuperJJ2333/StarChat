import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/room_draft_store.dart';
import '../features/matrix/room_draft_store_test.dart' show MemoryStore;

void main() {
  for (final length in [100, 10000]) {
    test('draft snapshot CPU baseline with $length character draft', () async {
      final disk = MemoryStore();
      final store = RoomDraftStore(disk);
      final base = List.filled(length, '文').join();
      final samples = <int>[];
      for (var i = 0; i < 1000; i++) {
        final draft = RoomDraft('$base$i');
        final watch = Stopwatch()..start();
        store.save('synthetic-room', draft);
        watch.stop();
        samples.add(watch.elapsedMicroseconds);
      }
      await store.flush('synthetic-room');
      expect((await RoomDraftStore(disk).read('synthetic-room'))?.text,
          '${base}999');
      samples.sort();
      // CPU for synchronous save only; excludes IME, disk and frame rendering.
      // ignore: avoid_print
      print(jsonEncode({
        'scenario': 'draft_snapshot',
        'runner': 'desktop_flutter_test_not_device',
        'baseTextLength': length,
        'samples': samples.length,
        'p50_us': samples[499],
        'p95_us': samples[949],
        'p99_us': samples[989],
      }));
    });
  }
}
