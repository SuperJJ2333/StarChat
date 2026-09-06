import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';

final class _Transport
    implements RoomTimelineAdapter, RoomOptimisticTextAdapter {
  List<RoomMessageViewModel> events = [];
  String? txid;
  final sendResult = Completer<String>();
  final retryResult = Completer<void>();
  Completer<void>? historyResult;
  int retries = 0;
  @override
  List<RoomMessageViewModel> snapshot() => List.of(events);
  @override
  Future<String> sendTextWithTransaction(String text, String transactionId) {
    txid = transactionId;
    return sendResult.future;
  }

  @override
  Future<String> sendText(String text) => throw StateError('Use explicit txid');
  @override
  Future<void> retry(String transactionId) {
    retries++;
    return retryResult.future;
  }

  @override
  Future<Uint8List> loadAttachment(String eventId) async => Uint8List(0);
  @override
  Future<Uint8List?> loadThumbnail(String eventId) async => null;
  @override
  Future<void> loadHistory() async {
    await historyResult?.future;
  }

  @override
  Future<void> markRead() async {}
  @override
  Future<String> sendRedPacketReference(
          String packetId, String greeting) async =>
      'unused';
  @override
  Future<String> sendTransferReference(
          String transferId, String amount, String? note) async =>
      'unused';
  @override
  void dispose() {}
}

void main() {
  test(
      'history completion after disposal cannot notify or rebuild the timeline',
      () async {
    final transport = _Transport()..historyResult = Completer<void>();
    final controller = RoomTimelineController(transport);
    final history = controller.loadHistory();
    controller.dispose();
    transport.historyResult!.complete();
    await expectLater(history, completes);
  });

  test(
      'optimistic voice bubble keeps measured duration before network completes',
      () async {
    final transport = _Transport();
    final controller = RoomTimelineController(transport);
    final send = controller.sendText('[语音消息]',
        kind: RoomMessageKind.voice, voiceDuration: const Duration(seconds: 7));
    expect(
        controller.messages.single.voiceDuration, const Duration(seconds: 7));
    expect(controller.messages.single.deliveryState, RoomDeliveryState.sending);
    transport.sendResult.complete(r'$voice');
    await send;
    controller.dispose();
  });

  test(
      'ack without transaction metadata on later refresh preserves stable identity and order',
      () async {
    final transport = _Transport();
    final controller = RoomTimelineController(transport);
    final send = controller.sendText('hello');
    final local = controller.messages.single;
    transport.sendResult.complete(r'$server');
    await send;
    transport.events = [
      local.copyWith(id: r'$server', deliveryState: RoomDeliveryState.sent)
    ];
    await controller.refresh();
    // History reload may omit unsigned.transaction_id even after an earlier ack.
    transport.events = [
      RoomMessageViewModel(
          id: r'$server',
          senderId: 'me',
          text: 'hello',
          isOwn: true,
          deliveryState: RoomDeliveryState.sent,
          timestamp: local.timestamp.add(const Duration(seconds: 20)))
    ];
    await controller.refresh();
    expect(controller.messages, hasLength(1));
    expect(controller.messages.single.stableId, local.stableId);
    expect(controller.messages.single.timestamp, local.timestamp);
    controller.dispose();
  });

  test('retry publishes fresh local sending state before transport completes',
      () async {
    final transport = _Transport();
    final controller = RoomTimelineController(transport);
    final send = controller.sendText('failed');
    final local = controller.messages.single;
    transport.events = [
      local.copyWith(deliveryState: RoomDeliveryState.failed)
    ];
    transport.sendResult.completeError(StateError('offline'));
    await send;
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final retry = controller.retry(local.id);
    expect(controller.messages.single.deliveryState, RoomDeliveryState.sending);
    expect(
        controller.messages.single.timestamp.isAfter(local.timestamp), isTrue);
    expect(controller.messages.single.stableId, local.stableId);
    transport.events = [
      local.copyWith(deliveryState: RoomDeliveryState.sending)
    ];
    await controller.refresh();
    expect(controller.messages.single.deliveryState, RoomDeliveryState.sending);
    transport.retryResult.complete();
    await retry;
    controller.dispose();
  });

  test(
      'permission-denied echo survives refresh and retries its captured callback',
      () async {
    final transport = _Transport();
    var allowed = false;
    var sends = 0;
    String? sentTxid;
    final result = Completer<String>();
    final controller =
        RoomTimelineController(transport, canSendNow: () => allowed);
    await controller.sendText('reply', replyToEventId: r'$reply', send: (txid) {
      sends++;
      sentTxid = txid;
      return result.future;
    });
    final local = controller.messages.single;
    await controller.refresh();
    expect(controller.messages, hasLength(1));
    expect(controller.messages.single.deliveryState, RoomDeliveryState.failed);
    expect(sends, 0);
    allowed = true;
    final retry = controller.retry(local.id);
    expect(sends, 1);
    expect(sentTxid, local.stableId);
    expect(controller.messages.single.deliveryState, RoomDeliveryState.sending);
    result.complete(r'$accepted');
    await retry;
    expect(controller.messages.single.deliveryState, RoomDeliveryState.sent);
    expect(controller.messages.single.replyToEventId, r'$reply');
    controller.dispose();
  });
}
