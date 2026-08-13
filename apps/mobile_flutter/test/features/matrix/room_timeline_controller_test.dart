import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';

final class FakeTimelineAdapter implements RoomTimelineAdapter {
  final items = <RoomMessageViewModel>[];
  int disposed = 0;
  int marks = 0;
  @override Future<void> loadHistory() async {}
  @override Future<void> markRead() async => marks++;
  @override Future<void> retry(String transactionId) async {}
  @override Future<String> sendText(String text) async => 'event-1';
  @override List<RoomMessageViewModel> snapshot() => List.of(items);
  @override void dispose() => disposed++;
}

void main() {
  test('controller owns delivery state, read marker and adapter disposal', () async {
    final adapter = FakeTimelineAdapter();
    final controller = RoomTimelineController(adapter);
    await controller.sendText('你好');
    expect(controller.messages.single.deliveryState, RoomDeliveryState.sent);
    await controller.markRead();
    expect(adapter.marks, 1);
    controller.dispose();
    expect(adapter.disposed, 1);
  });
}
