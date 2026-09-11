import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import '../features/matrix/matrix_room_timeline_adapter_test.dart'
    show RetryRoom, RetryTimeline, openAdapter;

class _CountedEvent extends Event {
  _CountedEvent(Room room, int index)
      : super(
            room: room,
            eventId: 'synthetic-$index',
            senderId: 'member-${index % 1000}',
            type: EventTypes.Message,
            originServerTs: DateTime.utc(2026).add(Duration(seconds: index)),
            content: {'msgtype': 'm.text', 'body': 'synthetic fixture'});
  static int projections = 0;
  static int timestampReads = 0;
  @override
  DateTime get originServerTs {
    timestampReads++;
    return super.originServerTs;
  }

  @override
  String get text {
    projections++;
    return super.text;
  }
}

class _GroupRoom extends RetryRoom {
  @override
  User unsafeGetUserFromMemoryOrFallback(String id) =>
      User(id, room: this, displayName: id);
}

Event _qrJoin(Room room, int index) => Event(
    room: room,
    eventId: 'join-$index',
    senderId: '@member$index:test',
    stateKey: '@member$index:test',
    type: EventTypes.RoomMember,
    originServerTs: DateTime.utc(2026).add(Duration(seconds: index * 50)),
    content: {'membership': 'join', 'com.changliao.join_source': 'qr'});

void main() {
  test('group window matches existing notice tie order and uses linear merge',
      () async {
    final room = _GroupRoom();
    expect(room.isDirectChat, isFalse);
    final timeline = RetryTimeline();
    timeline.events.addAll([
      ...List.generate(50000, (i) => _CountedEvent(room, 49999 - i)),
      ...List.generate(1000, (i) => _qrJoin(room, i)),
    ]);
    final adapter = await openAdapter(room, timeline);
    final expected = adapter.snapshot().map((m) => (m.id, m.text)).toList();
    final controller = RoomTimelineController(adapter, windowed: true);
    var notifications = 0;
    final workCounts = <int>[];
    controller.addListener(() => notifications++);
    for (var i = 0; i < 2; i++) {
      _CountedEvent.timestampReads = 0;
      _CountedEvent.projections = 0;
      await controller.refresh();
      workCounts.add(_CountedEvent.timestampReads);
      expect(_CountedEvent.timestampReads, lessThan(50000 * 4),
          reason:
              'each refresh must merge messages and notices in linear work');
      expect(_CountedEvent.projections, lessThanOrEqualTo(42));
    }
    expect(adapter.allMessages.map((m) => (m.id, m.text)).toList(), expected);
    expect(notifications, 0);
    timeline.events.insert(0, _CountedEvent(room, 50000));
    _CountedEvent.timestampReads = 0;
    await controller.refresh();
    expect(_CountedEvent.timestampReads, lessThan(50001 * 4));
    // ignore: avoid_print
    print(jsonEncode({
      'scenario': 'sdk_group_notice_linear_merge',
      'runner': 'desktop_not_device',
      'messages': 50000,
      'qrNotices': 1000,
      'noopTimestampReads': workCounts,
      'appendTimestampReads': _CountedEvent.timestampReads,
    }));
    expect(controller.messages.last.id, 'synthetic-50000');
    expect(notifications, 1);
    controller.dispose();
    await room.client.dispose();
  });
  test(
      'real SDK 50000-history window projects bounded models across refresh and anchors',
      () async {
    final room = RetryRoom();
    final timeline = RetryTimeline();
    timeline.events
        .addAll(List.generate(50000, (i) => _CountedEvent(room, 49999 - i)));
    final adapter = await openAdapter(room, timeline);
    _CountedEvent.projections = 0;
    final controller = RoomTimelineController(adapter, windowed: true);
    expect(controller.messages.length, 40);
    expect(_CountedEvent.projections, lessThanOrEqualTo(42));
    final first = controller.messages;
    var notifications = 0;
    controller.addListener(() => notifications++);
    final samples = <int>[];
    for (var i = 0; i < 40; i++) {
      _CountedEvent.projections = 0;
      final watch = Stopwatch()..start();
      await controller.refresh();
      watch.stop();
      expect(identical(controller.messages, first), isTrue);
      expect(_CountedEvent.projections, lessThanOrEqualTo(42));
      if (i >= 10) samples.add(watch.elapsedMicroseconds);
    }
    expect(notifications, 0);
    for (final id in ['synthetic-25000', 'synthetic-10', 'synthetic-49000']) {
      _CountedEvent.projections = 0;
      expect(await controller.openAnchor(id), isTrue);
      expect(controller.messages.length, lessThanOrEqualTo(200));
      expect(_CountedEvent.projections, lessThanOrEqualTo(202));
      expect(controller.indexOf(id), isNotNull);
    }
    samples.sort();
    // ignore: avoid_print
    print(jsonEncode({
      'scenario': 'sdk_bounded_window_refresh',
      'runner': 'desktop_not_device',
      'history': 50000,
      'activeRows': 40,
      'maxRows': 200,
      'samples': samples.length,
      'p50_us': samples[14],
      'p95_us': samples[28],
      'p99_us': samples[29]
    }));
    controller.dispose();
    await room.client.dispose();
  });
}
