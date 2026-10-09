import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/network_state_manager.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_message.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';

// Real controller/network recovery with synthetic transport and Matrix rows.
// A future outbox timestamp makes insertion deterministic without a fake clock.
class ControlledAdapter
    implements RoomTimelineAdapter, RoomOptimisticTextAdapter {
  final rows = <RoomMessageViewModel>[];
  final secondAttempt = Completer<String>();
  final retryAdmitted = Completer<void>();
  final transactions = <String>[];
  bool failFirst = false;

  @override
  Future<String> sendTextWithTransaction(String text, String transactionId) {
    transactions.add(transactionId);
    if (failFirst && transactions.length == 1) {
      return Future<String>.error(
          const SocketException('synthetic transport failure'));
    }
    if (transactions.length == 2 && !retryAdmitted.isCompleted) {
      retryAdmitted.complete();
    }
    return secondAttempt.future;
  }

  @override
  List<RoomMessageViewModel> snapshot() => List.of(rows);
  @override
  Future<String> sendText(String text) => throw UnimplementedError();
  @override
  Future<String> sendRedPacketReference(String packetId, String greeting,
          {String? mode, String? recipientId, String? recipientMatrixId}) =>
      throw UnimplementedError();
  @override
  Future<String> sendTransferReference(
          String transferId, String amount, String? note,
          {String? receiverId, String? receiverMatrixId}) =>
      throw UnimplementedError();
  @override
  Future<Uint8List> loadAttachment(String eventId) =>
      throw UnimplementedError();
  @override
  Future<Uint8List?> loadThumbnail(String eventId) async => null;
  @override
  Future<void> retry(String transactionId) => throw UnimplementedError();
  @override
  Future<void> loadHistory() async {}
  @override
  Future<void> markRead() async {}
  @override
  void dispose() {}
}

final insertionTime = DateTime.utc(2050, 1, 1);
const transaction = 'synthetic-tx-own';
const serverId = 'synthetic-server-own';

OutboxMessage syntheticOutbox() => OutboxMessage(
    localId: 'synthetic-local-own',
    txid: transaction,
    receiverId: 'synthetic-peer',
    roomId: 'synthetic-room',
    content: 'synthetic own',
    createdAt: insertionTime,
    updatedAt: insertionTime);

RoomMessageViewModel peer() => RoomMessageViewModel(
    id: 'synthetic-peer-event',
    senderId: 'synthetic-peer',
    text: 'synthetic peer',
    isOwn: false,
    deliveryState: RoomDeliveryState.sent,
    timestamp: insertionTime.add(const Duration(seconds: 1)));

RoomMessageViewModel own({required bool localEcho}) => RoomMessageViewModel(
    id: serverId,
    transactionId: transaction,
    senderId: 'synthetic-own',
    text: 'synthetic own',
    isOwn: true,
    deliveryState: RoomDeliveryState.sent,
    timestamp: insertionTime.add(const Duration(seconds: 2)),
    isSdkLocalEcho: localEcho);

List<String> order(RoomTimelineController controller) =>
    controller.messages.map((row) => row.stableId).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('unchanged pending refresh keeps original insertion before later peer',
      () async {
    final network = NetworkStateManager();
    final adapter = ControlledAdapter()..failFirst = true;
    final controller =
        RoomTimelineController(adapter, networkStateManager: network);
    try {
      expect(
          await controller.sendText('synthetic own',
              outboxRow: syntheticOutbox()),
          isNull);
      adapter.rows.add(peer());
      await controller.refresh();
      final before = controller.messages.first.timestamp;
      for (var count = 0; count < 4; count++) {
        await controller.refresh();
      }
      expect(order(controller), [transaction, 'synthetic-peer-event']);
      expect(controller.messages.first.timestamp, before);
      expect(controller.messages.first.deliveryState,
          RoomDeliveryState.waitingNetwork);
      expect(adapter.transactions, [transaction]);
    } finally {
      controller.dispose();
      network.dispose();
    }
  });

  test('automatic recovery retains insertion before ACK and reuses transaction',
      () async {
    final network = NetworkStateManager();
    final adapter = ControlledAdapter()..failFirst = true;
    final controller =
        RoomTimelineController(adapter, networkStateManager: network);
    try {
      await controller.sendText('synthetic own', outboxRow: syntheticOutbox());
      adapter.rows.add(peer());
      await controller.refresh();
      final before = order(controller);
      final originalTimestamp = controller.messages.first.timestamp;
      network.reportSuccess();
      await adapter.retryAdmitted.future.timeout(const Duration(seconds: 1));
      expect(order(controller), before,
          reason: 'Automatic recovery should not change original insertion '
              'position merely by restarting an unacknowledged send attempt');
      expect(controller.messages.first.timestamp, originalTimestamp);
      expect(
          controller.messages.first.deliveryState, RoomDeliveryState.sending);
      expect(adapter.transactions, [transaction, transaction]);
      expect(adapter.secondAttempt.isCompleted, isFalse);
      for (var count = 0; count < 4; count++) {
        await controller.refresh();
      }
      expect(order(controller), before);
      expect(controller.messages.first.timestamp, originalTimestamp);
    } finally {
      if (!adapter.secondAttempt.isCompleted) {
        adapter.secondAttempt.complete(serverId);
      }
      await Future<void>.delayed(Duration.zero);
      controller.dispose();
      network.dispose();
    }
  });

  test('manual retry retains insertion before ACK and reuses transaction',
      () async {
    final network = NetworkStateManager();
    final adapter = ControlledAdapter()..failFirst = true;
    final controller =
        RoomTimelineController(adapter, networkStateManager: network);
    try {
      await controller.sendText('synthetic own', outboxRow: syntheticOutbox());
      adapter.rows.add(peer());
      await controller.refresh();
      final before = order(controller);
      final originalTimestamp = controller.messages.first.timestamp;
      final retry = controller.retry(transaction);
      await adapter.retryAdmitted.future.timeout(const Duration(seconds: 1));
      expect(order(controller), before,
          reason: 'Manual retry should not change original insertion '
              'position merely by restarting an unacknowledged send attempt');
      expect(controller.messages.first.timestamp, originalTimestamp);
      expect(
          controller.messages.first.deliveryState, RoomDeliveryState.sending);
      expect(adapter.transactions, [transaction, transaction]);
      expect(adapter.secondAttempt.isCompleted, isFalse);
      for (var count = 0; count < 4; count++) {
        await controller.refresh();
      }
      expect(order(controller), before);
      expect(controller.messages.first.timestamp, originalTimestamp);
      adapter.secondAttempt.complete(serverId);
      await retry;
    } finally {
      if (!adapter.secondAttempt.isCompleted) {
        adapter.secondAttempt.complete(serverId);
      }
      await Future<void>.delayed(Duration.zero);
      controller.dispose();
      network.dispose();
    }
  });

  test('first confirmed sync applies canonical order once after retry ACK',
      () async {
    final network = NetworkStateManager();
    final adapter = ControlledAdapter()..failFirst = true;
    final controller =
        RoomTimelineController(adapter, networkStateManager: network);
    try {
      await controller.sendText('synthetic own', outboxRow: syntheticOutbox());
      network.reportSuccess();
      await adapter.retryAdmitted.future.timeout(const Duration(seconds: 1));
      // Assumption: SDK chronology is peer before own, as can happen if peer
      // arrives before SDK local-echo admission. This is a controlled adapter
      // input, not a reproduced real send-pipeline delay.
      adapter.rows.addAll([peer(), own(localEcho: true)]);
      await controller.refresh();
      expect(order(controller), [transaction, 'synthetic-peer-event']);
      adapter.secondAttempt.complete(serverId);
      await Future<void>.delayed(Duration.zero);
      await controller.refresh();
      expect(order(controller), [transaction, 'synthetic-peer-event']);
      adapter.rows[1] = own(localEcho: false);
      await controller.refresh();
      expect(order(controller), ['synthetic-peer-event', transaction]);
      expect(
          controller.messages.last.timestamp, own(localEcho: false).timestamp);
      final authoritative = order(controller);
      for (var count = 0; count < 4; count++) {
        await controller.refresh();
      }
      expect(order(controller), authoritative,
          reason:
              'Unchanged confirmed inputs must not keep changing relative order');
      expect(controller.messages, hasLength(2));
      expect(controller.indexOf(transaction), controller.indexOf(serverId));
      expect(adapter.transactions, [transaction, transaction]);
    } finally {
      if (!adapter.secondAttempt.isCompleted) {
        adapter.secondAttempt.complete(serverId);
      }
      controller.dispose();
      network.dispose();
    }
  });
}
