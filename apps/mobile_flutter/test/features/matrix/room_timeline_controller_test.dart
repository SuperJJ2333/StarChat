import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';

final class FakeTimelineAdapter implements RoomTimelineAdapter {
  final items = <RoomMessageViewModel>[];
  int disposed = 0;
  int marks = 0;
  final redPackets = <String>[];
  @override
  Future<Uint8List> loadAttachment(String eventId) async =>
      Uint8List.fromList([1, 2, 3]);
  @override
  Future<void> loadHistory() async {}
  @override
  Future<void> markRead() async => marks++;
  @override
  Future<void> retry(String transactionId) async {}
  @override
  Future<String> sendText(String text) async => 'event-1';
  @override
  Future<String> sendRedPacketReference(
    String packetId,
    String greeting,
  ) async {
    redPackets.add('$packetId:$greeting');
    return 'event-red-packet';
  }

  @override
  List<RoomMessageViewModel> snapshot() => List.of(items);
  @override
  void dispose() => disposed++;
}

void main() {
  test('controller owns delivery state, read marker and adapter disposal',
      () async {
    final adapter = FakeTimelineAdapter();
    final controller = RoomTimelineController(adapter);
    await controller.sendText('你好');
    expect(controller.messages.single.deliveryState, RoomDeliveryState.sent);
    await controller.markRead();
    expect(adapter.marks, 1);
    await controller.sendRedPacketReference('packet-1', '恭喜发财');
    expect(adapter.redPackets, ['packet-1:恭喜发财']);
    controller.dispose();
    expect(adapter.disposed, 1);
  });

  test('time separators appear at the first message and after five minutes',
      () {
    final first = DateTime(2026, 8, 17, 9);
    expect(shouldShowMessageTimeSeparator(null, first), isTrue);
    expect(
      shouldShowMessageTimeSeparator(
        first,
        first.add(const Duration(minutes: 4, seconds: 59)),
      ),
      isFalse,
    );
    expect(
      shouldShowMessageTimeSeparator(
        first,
        first.add(const Duration(minutes: 5)),
      ),
      isTrue,
    );
  });
}
