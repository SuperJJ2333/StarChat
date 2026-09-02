import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/features/transfer/chat_transfer_controller.dart';

final class FakeTransferBusiness implements ChatTransferBusinessGateway {
  int creates = 0;
  String? receiverId;
  String? amount;
  Object? error;

  @override
  Future<Map<String, dynamic>> create(
      {required String receiverId, required String amount, String? note}) async {
    creates++;
    this.receiverId = receiverId;
    this.amount = amount;
    final failure = error;
    if (failure != null) throw failure;
    return {'id': 'transfer-1', 'status': 'PENDING', 'fee': '0.10'};
  }
}

final class FakeTransferReference implements ChatTransferReferenceGateway {
  int sends = 0;
  bool fail = false;
  String? lastTransferId;

  @override
  Future<void> sendReference(
      String transferId, String amount, String? note) async {
    sends++;
    lastTransferId = transferId;
    if (fail) throw Exception('matrix unavailable');
  }
}

void main() {
  test('chat transfer creates once and shares to the conversation', () async {
    final business = FakeTransferBusiness();
    final references = FakeTransferReference();
    final controller = ChatTransferController(
      business: business,
      references: references,
    );

    await controller.submit(
        receiverId: 'user-alice', amount: '20.00', note: '午饭');
    expect(controller.state.status, ChatTransferStatus.sent);
    expect(controller.state.transferId, 'transfer-1');
    expect(business.creates, 1);
    expect(business.receiverId, 'user-alice');
    expect(references.sends, 1);
    expect(references.lastTransferId, 'transfer-1');
  });

  test('balance insufficient error maps to the exact transfer message',
      () async {
    final controller = ChatTransferController(
      business: FakeTransferBusiness()
        ..error = const BusinessApiException(
            statusCode: 422,
            code: 'CHAT_TRANSFER_BALANCE_INSUFFICIENT',
            message: '转账失败，账户余额不足'),
      references: FakeTransferReference(),
    );

    await controller.submit(receiverId: 'user-alice', amount: '9999.00');
    expect(controller.state.status, ChatTransferStatus.failed);
    expect(controller.state.message, '转账失败，账户余额不足');
  });

  test('share retry never creates a second authoritative transfer', () async {
    final business = FakeTransferBusiness();
    final references = FakeTransferReference()..fail = true;
    final controller = ChatTransferController(
      business: business,
      references: references,
    );

    await controller.submit(receiverId: 'user-alice', amount: '5.00');
    expect(controller.state.status, ChatTransferStatus.shareFailed);
    expect(business.creates, 1);

    references.fail = false;
    await controller.retryShare();
    expect(controller.state.status, ChatTransferStatus.sent);
    expect(business.creates, 1);
    expect(references.sends, 2);
  });
}
