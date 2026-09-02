import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';

final class FakeTimelineAdapter implements RoomTimelineAdapter {
  final items = <RoomMessageViewModel>[];
  int disposed = 0;
  int marks = 0;
  final redPackets = <String>[];
  int retries = 0;
  Object? sendFailure;
  @override
  Future<Uint8List> loadAttachment(String eventId) async =>
      Uint8List.fromList([1, 2, 3]);
  @override
  Future<Uint8List?> loadThumbnail(String eventId) async => null;
  int historyPages = 1; // 每次加载追加的消息数；0 表示已无更多
  int historyCalls = 0;
  @override
  Future<void> loadHistory() async {
    historyCalls++;
    for (var i = 0; i < historyPages; i++) {
      items.insert(
        0,
        RoomMessageViewModel(
          id: 'history-$historyCalls-$i',
          senderId: 'peer',
          text: '早前消息',
          isOwn: false,
          deliveryState: RoomDeliveryState.sent,
          timestamp: DateTime.utc(2026, 8, 1),
        ),
      );
    }
  }
  @override
  Future<void> markRead() async => marks++;
  int retryCalls = 0;
  @override
  Future<void> retry(String transactionId) async {
    retryCalls++;
  }
  @override
  Future<String> sendText(String text) async {
    final failure = sendFailure;
    if (failure != null) throw failure;
    return 'event-1';
  }
  @override
  Future<String> sendRedPacketReference(
    String packetId,
    String greeting,
  ) async {
    redPackets.add('$packetId:$greeting');
    return 'event-red-packet';
  }

  final transfers = <String>[];
  @override
  Future<String> sendTransferReference(
    String transferId,
    String amount,
    String? note,
  ) async {
    transfers.add('$transferId:$amount:$note');
    return 'event-transfer';
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
    await controller.sendTransferReference('transfer-1', '20.00', '午饭');
    expect(adapter.transfers, ['transfer-1:20.00:午饭']);
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

  test('message copy keeps attachment mime type for GIF action policy', () {
    final message = RoomMessageViewModel(
      id: r'$gif',
      senderId: '@alice:example.test',
      text: 'wave.gif',
      isOwn: true,
      deliveryState: RoomDeliveryState.sending,
      timestamp: DateTime.utc(2026, 8, 17),
      kind: RoomMessageKind.image,
      mimeType: 'image/gif',
    );

    final sent = message.copyWith(deliveryState: RoomDeliveryState.sent);

    expect(sent.mimeType, 'image/gif');
  });

  test('failed send retries in place without duplicating the message',
      () async {
    final adapter = FakeTimelineAdapter();
    adapter.sendFailure = StateError('network down');
    final controller = RoomTimelineController(adapter);

    await controller.sendText('你好');
    expect(
      controller.messages.where((m) => m.text == '你好').length,
      1,
      reason: '失败只标记一次，不产生副本',
    );
    expect(controller.messages.single.deliveryState, RoomDeliveryState.failed);

    adapter.sendFailure = null;
    // 真实 SDK：sendAgain 复用同一事件，重发成功后时间线中出现已发送事件。
    adapter.items.add(controller.messages.single.copyWith(
      deliveryState: RoomDeliveryState.sent,
    ));
    await controller.retry(controller.messages.single.id);

    expect(adapter.retryCalls, 1);
    expect(
      controller.messages.where((m) => m.text == '你好').length,
      1,
      reason: '重发复用同一事件，不插入新消息',
    );
  });

  test('loadHistory reports loading and exhaustion for top-of-list UI',
      () async {
    final adapter = FakeTimelineAdapter();
    // 初始只有一条最新消息。
    adapter.items.add(RoomMessageViewModel(
      id: 'm-1',
      senderId: 'peer',
      text: '最新',
      isOwn: false,
      deliveryState: RoomDeliveryState.sent,
      timestamp: DateTime.utc(2026, 8, 2),
    ));
    final controller = RoomTimelineController(adapter);

    expect(controller.historyLoading, isFalse);
    expect(controller.historyExhausted, isFalse);

    await controller.loadHistory();
    expect(controller.historyLoading, isFalse,
        reason: '加载完成后停用 loading 图标');
    expect(controller.historyExhausted, isFalse);
    expect(controller.messages.length, 2);
    expect(adapter.historyCalls, 1);

    // 已无更多历史：加载后消息数不增长 → exhausted，重复调用为空操作。
    adapter.historyPages = 0;
    await controller.loadHistory();
    expect(controller.historyExhausted, isTrue,
        reason: '顶部显示“没有更多了”');
    expect(controller.messages.length, 2);
    await controller.loadHistory();
    expect(adapter.historyCalls, 2, reason: '耗尽后不再发起加载');
  });
}
