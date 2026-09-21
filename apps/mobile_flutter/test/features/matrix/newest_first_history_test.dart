import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_viewport.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_room_timeline_adapter.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_message.dart';

RoomMessageViewModel model(int id) => RoomMessageViewModel(
    id: '$id',
    senderId: 'fixture',
    text: '$id',
    isOwn: false,
    deliveryState: RoomDeliveryState.sent,
    timestamp: DateTime.utc(2026).add(Duration(seconds: id)));

class Adapter extends Fake implements RoomTimelineAdapter {
  @override
  List<RoomMessageViewModel> snapshot() => List.generate(1000, model);
  @override
  void dispose() {}
}

class LazyCapability extends Fake
    implements RoomTimelineCapability, RoomNewestFirstTimelineSource {
  LazyCapability(this.viewport);
  final RoomTimelineViewport<int> viewport;
  @override
  List<RoomMessageViewModel> snapshot() => viewport.snapshot();
  @override
  Iterable<RoomMessageViewModel> get newestFirstMessages =>
      viewport.newestFirst;
  @override
  Iterable<RoomMessageViewModel> historyNewestFirst({String? beforeEventId}) =>
      viewport.historyNewestFirst(beforeEventId: beforeEventId);
  @override
  void dispose() {}
}

void main() {
  test('newest-first projects only the requested 600 of 50000 references', () {
    var projections = 0;
    final viewport = RoomTimelineViewport<int>(
        idOf: (id) => '$id',
        project: (id) {
          projections++;
          return model(id);
        });
    viewport.update(List.generate(50000, (id) => id));
    final Iterable<RoomMessageViewModel> newest =
        (viewport as dynamic).newestFirst;
    expect(projections, 0);
    final first = newest.take(600).toList();
    expect(projections, 600);
    expect(first.first.id, '49999');
    expect(first.last.id, '49400');
    final iterator =
        viewport.historyNewestFirst(beforeEventId: '49400').iterator;
    expect(iterator.moveNext(), isTrue);
    expect(iterator.current.id, '49399');
    viewport.update(List.generate(50001, (id) => id));
    expect(iterator.moveNext(), isTrue);
    expect(iterator.current.id, '49398');
  });

  test('controller exposes newest-first legacy messages without sorting', () {
    final controller = RoomTimelineController(Adapter());
    final Iterable<RoomMessageViewModel> newest =
        (controller as dynamic).newestFirstMessages;
    expect(newest.take(3).map((m) => m.id), ['999', '998', '997']);
    controller.dispose();
  });

  test('adapter and controller preserve the lazy source contract', () {
    var projections = 0;
    final viewport = RoomTimelineViewport<int>(
        idOf: (id) => '$id',
        project: (id) {
          projections++;
          return model(id);
        });
    viewport.update(List.generate(50000, (id) => id));
    final controller = RoomTimelineController(
        MatrixRoomTimelineAdapter(LazyCapability(viewport)),
        windowed: true);
    projections = 0;
    final first = controller.newestFirstMessages.take(600).toList();
    expect(projections, 600);
    expect(first.first.id, '49999');
    expect(first.last.id, '49400');
    projections = 0;
    final next = controller
        .historyNewestFirst(beforeEventId: '49400')
        .take(600)
        .toList();
    expect(projections, 600);
    expect(next.first.id, '49399');
    expect(next.last.id, '48800');
    final now = DateTime.utc(2026);
    controller.restoreOutboxMessage(OutboxMessage(
        localId: 'pending',
        txid: 'pending',
        receiverId: 'fixture',
        content: 'pending',
        createdAt: now,
        updatedAt: now,
        status: OutboxStatus.failed));
    expect(controller.newestFirstMessages.first.id, 'pending');
    expect(controller.historyNewestFirst(beforeEventId: 'pending').first.id,
        '49999');
    controller.restoreOutboxMessage(OutboxMessage(
        localId: 'existing',
        txid: '49999',
        receiverId: 'fixture',
        content: 'shadow',
        createdAt: now,
        updatedAt: now,
        status: OutboxStatus.failed));
    final head = controller.newestFirstMessages.take(3).toList();
    expect(head.map((m) => m.id), ['pending', '49999', '49998']);
    expect(head[1].text, '49999',
        reason: 'authoritative source keeps precedence');
    controller.dispose();
  });
}
