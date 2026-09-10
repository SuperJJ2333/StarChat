import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';

// Deterministic synthetic data only. This measures controller CPU in a desktop
// test runner, NOT mobile frame/IME latency. Keep workload unchanged across runs.
class _SyntheticTimeline implements RoomTimelineAdapter {
  _SyntheticTimeline(int count)
      : items = List.generate(
            count,
            (i) => RoomMessageViewModel(
                  id: 'synthetic-$i',
                  senderId: 'member-${i % 1000}',
                  text: 'synthetic message',
                  isOwn: false,
                  deliveryState: RoomDeliveryState.sent,
                  timestamp: DateTime.utc(2026).add(Duration(seconds: i)),
                ));
  final List<RoomMessageViewModel> items;
  @override
  List<RoomMessageViewModel> snapshot() => List.of(items);
  @override
  void dispose() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final count in [300, 50000]) {
    test('synthetic timeline baseline $count messages / 1000 sender pool',
        () async {
      final adapter = _SyntheticTimeline(count);
      final controller = RoomTimelineController(adapter);
      var notifications = 0;
      controller.addListener(() => notifications++);
      for (var i = 0; i < 10; i++) {
        await controller.refresh();
      }
      notifications = 0;
      final samples = <int>[];
      for (var i = 0; i < 100; i++) {
        final watch = Stopwatch()..start();
        await controller.refresh();
        watch.stop();
        samples.add(watch.elapsedMicroseconds);
      }
      samples.sort();
      // No time-based pass/fail on a shared host. Mobile acceptance uses a
      // profile build, FrameTiming/Perfetto and a separately recorded device.
      // ignore: avoid_print
      print(jsonEncode({
        'scenario': 'unchanged_timeline_refresh',
        'runner': 'desktop_flutter_test_not_device',
        'messages': count,
        'senderPoolSize': 1000,
        'distinctSenders': adapter.items.map((e) => e.senderId).toSet().length,
        'includesMembershipWorkload': false,
        'samples': samples.length,
        'p50_us': samples[49],
        'p95_us': samples[94],
        'p99_us': samples[98],
        'notifications': notifications,
      }));
      expect(controller.messages.length, count);
      expect(controller.messages.map((e) => e.stableId).toSet().length, count);
      controller.dispose();
    });
  }
}
