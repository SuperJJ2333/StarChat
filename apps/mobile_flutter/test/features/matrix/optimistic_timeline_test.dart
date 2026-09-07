import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'room_timeline_controller_test.dart' show FakeTimelineAdapter;

class EchoAdapter extends FakeTimelineAdapter implements RoomOptimisticTextAdapter {
  final pending = Completer<String>();
  String? transaction;
  @override
  Future<String> sendTextWithTransaction(String text, String transactionId) {
    transaction = transactionId;
    return pending.future;
  }
}

void main() {
  test('sync cannot remove pending bubble or double it with SDK local echo', () async {
    final adapter = EchoAdapter();
    final controller = RoomTimelineController(adapter);
    final send = controller.sendText('hello');
    final optimistic = controller.messages.single;
    await controller.refresh();
    expect(controller.messages.single.stableId, optimistic.stableId);
    adapter.items.add(RoomMessageViewModel(
      id: adapter.transaction!, transactionId: adapter.transaction,
      senderId: 'me', text: 'hello', isOwn: true,
      deliveryState: RoomDeliveryState.sending,
      timestamp: optimistic.timestamp.add(const Duration(seconds: 1)),
    ));
    await controller.refresh();
    expect(controller.messages, hasLength(1));
    expect(controller.messages.single.timestamp, optimistic.timestamp);
    adapter.pending.complete('server-id');
    await send;
    adapter.items[0] = adapter.items[0].copyWith(id: 'server-id', deliveryState: RoomDeliveryState.sent);
    await controller.refresh();
    expect(controller.messages, hasLength(1));
    expect(controller.messages.single.stableId, optimistic.stableId);
    expect(controller.messages.single.timestamp, optimistic.timestamp);
    controller.dispose();
  });

  test('failed local message stays in original chronological position on refresh', () async {
    final adapter = EchoAdapter();
    final controller = RoomTimelineController(adapter);
    final send = controller.sendText('failed');
    adapter.pending.completeError(StateError('offline'));
    await send;
    final failed = controller.messages.single;
    adapter.items.add(RoomMessageViewModel(id: 'later', senderId: 'peer', text: 'later',
      isOwn: false, deliveryState: RoomDeliveryState.sent,
      timestamp: failed.timestamp.add(const Duration(seconds: 2))));
    await controller.refresh();
    expect(controller.messages.map((m) => m.text), ['failed', 'later']);
    expect(controller.messages.first.deliveryState, RoomDeliveryState.failed);
    controller.dispose();
  });
}
