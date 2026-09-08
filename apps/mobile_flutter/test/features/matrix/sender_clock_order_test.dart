import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'optimistic_timeline_test.dart' show EchoAdapter;

RoomMessageViewModel incoming(String id, DateTime at) => RoomMessageViewModel(
    id: id,
    senderId: 'peer',
    text: id,
    isOwn: false,
    deliveryState: RoomDeliveryState.sent,
    timestamp: at);

void main() {
  test('HTTP ack keeps insertion until a timestamp arrives through sync',
      () async {
    final adapter = EchoAdapter();
    final serverTime = DateTime.now().add(const Duration(minutes: 2));
    adapter.items.add(incoming('previous', serverTime));
    final controller = RoomTimelineController(adapter);
    final sending = controller.sendText('new');
    final tx = controller.messages.last.stableId;
    adapter.items.add(RoomMessageViewModel(
        id: 'server-new',
        transactionId: tx,
        senderId: 'me',
        text: 'new',
        isOwn: true,
        deliveryState: RoomDeliveryState.sent,
        timestamp: DateTime.now(),
        isSdkLocalEcho: true));
    adapter.pending.complete('server-new');
    await sending;
    await controller.refresh();
    expect(controller.messages.map((m) => m.text), ['previous', 'new']);
    adapter.items[1] = RoomMessageViewModel(
        id: 'server-new',
        transactionId: tx,
        senderId: 'me',
        text: 'new',
        isOwn: true,
        deliveryState: RoomDeliveryState.sent,
        timestamp: serverTime.add(const Duration(seconds: 1)));
    await controller.refresh();
    expect(controller.messages.last.timestamp, adapter.items.last.timestamp);
    expect(controller.messages.last.stableId, tx);
    controller.dispose();
  });
  test('phone clock behind server cannot move a pending send into history',
      () async {
    final adapter = EchoAdapter();
    final serverTime = DateTime.now().add(const Duration(minutes: 2));
    adapter.items.add(incoming('previous', serverTime));
    final controller = RoomTimelineController(adapter);
    final sending = controller.sendText('new');
    await controller.refresh();
    expect(controller.messages.map((m) => m.text), ['previous', 'new']);
    adapter.pending.complete('server-new');
    await sending;
    expect(controller.messages.map((m) => m.text), ['previous', 'new']);
    controller.dispose();
  });

  for (final syncBeforeResponse in [false, true]) {
    test(
        'confirmed send uses server order without reopening (sync first=$syncBeforeResponse)',
        () async {
      final adapter = EchoAdapter();
      final controller = RoomTimelineController(adapter);
      final sending = controller.sendText('sent');
      final local = controller.messages.single;
      final serverTime = local.timestamp.subtract(const Duration(minutes: 2));
      adapter.items.add(local.copyWith(
          id: 'server-new',
          deliveryState: RoomDeliveryState.sent,
          timestamp: serverTime));
      adapter.items
          .add(incoming('reply', serverTime.add(const Duration(seconds: 1))));
      if (syncBeforeResponse) await controller.refresh();
      adapter.pending.complete('server-new');
      await sending;
      await controller.refresh();
      expect(controller.messages.map((m) => m.text), ['sent', 'reply']);
      expect(controller.messages.first.timestamp, serverTime);
      expect(controller.messages.first.stableId, local.stableId);
      await controller.refresh();
      expect(controller.messages.first.timestamp, serverTime);
      final reopened = RoomTimelineController(adapter);
      expect(controller.messages.map((m) => m.id),
          reopened.messages.map((m) => m.id));
      reopened.dispose();
      controller.dispose();
    });
  }
}
