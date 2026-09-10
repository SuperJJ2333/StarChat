import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import '../features/matrix/matrix_room_timeline_adapter_test.dart'
    show RetryRoom, RetryTimeline, openAdapter;
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
  test('SDK projection retains 50000 models on unchanged refresh', () async {
    final room = RetryRoom();
    final timeline = RetryTimeline();
    for (var i = 49999; i >= 0; i--) {
      timeline.events.add(Event(
          room: room,
          type: EventTypes.Message,
          eventId: 'synthetic-$i',
          senderId: 'member-${i % 1000}',
          originServerTs: DateTime.utc(2026).add(Duration(seconds: i)),
          content: {'msgtype': 'm.text', 'body': 'synthetic fixture'}));
    }
    final adapter = await openAdapter(room, timeline);
    final first = adapter.snapshot();
    final samples = <int>[];
    for (var i = 0; i < 40; i++) {
      final watch = Stopwatch()..start();
      final next = adapter.snapshot();
      watch.stop();
      expect(identical(first, next), isTrue);
      if (i >= 10) samples.add(watch.elapsedMicroseconds);
    }
    samples.sort();
    // ignore: avoid_print
    print(jsonEncode({
      'scenario': 'sdk_unchanged_projection',
      'runner': 'desktop_flutter_test_not_device',
      'messages': first.length,
      'samples': samples.length,
      'p50_us': samples[14],
      'p95_us': samples[28],
      'p99_us': samples[29],
      'includesMembershipWorkload': false
    }));
    expect(first.length, 50000);
    timeline.events.insert(
        0,
        Event(
            room: room,
            type: EventTypes.Message,
            eventId: 'synthetic-new',
            senderId: 'member-1',
            originServerTs: DateTime.utc(2026),
            content: {'msgtype': 'm.text', 'body': 'synthetic fixture'}));
    final appended = adapter.snapshot();
    expect(appended.last.id, 'synthetic-new');
    for (var i = 0; i < first.length; i++) {
      expect(identical(first[i], appended[i]), isTrue);
    }
  });

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
      expect(notifications, 0);
      expect(controller.messages.length, count);
      expect(controller.messages.map((e) => e.stableId).toSet().length, count);
      controller.dispose();
    });
  }
}
