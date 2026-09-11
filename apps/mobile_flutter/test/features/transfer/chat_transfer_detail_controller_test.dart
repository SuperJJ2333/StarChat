import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/transfer/chat_transfer_detail_controller.dart';

final class FakeGateway implements ChatTransferDetailGateway {
  int _epoch = 1;
  final invalidations = StreamController<void>.broadcast();
  final details = <Object?>[];
  final acceptResults = <Object?>[];
  final declineResults = <Object?>[];
  int detailCalls = 0;
  int acceptCalls = 0;
  int declineCalls = 0;

  @override
  int get sessionEpoch => _epoch;

  @override
  Stream<void> get sessionInvalidations => invalidations.stream;

  void invalidate({bool advanceEpoch = true}) {
    if (advanceEpoch) _epoch++;
    invalidations.add(null);
  }

  @override
  Future<Map<String, dynamic>> detail(String transferId) =>
      _next(details, ++detailCalls);

  @override
  Future<Map<String, dynamic>> accept(String transferId) =>
      _next(acceptResults, ++acceptCalls);

  @override
  Future<Map<String, dynamic>> decline(String transferId) =>
      _next(declineResults, ++declineCalls);

  Future<Map<String, dynamic>> _next(List<Object?> results, int call) {
    if (results.isEmpty) return Future<Map<String, dynamic>>.error('missing');
    final value = results.removeAt(0);
    if (value is Future<Map<String, dynamic>>) return value;
    if (value is Map<String, dynamic>) return Future.value(value);
    return Future<Map<String, dynamic>>.error(value ?? 'failed $call');
  }

  Future<void> close() => invalidations.close();
}

Map<String, dynamic> _detail(String status, {String? billId}) => {
      'id': 'transfer-1',
      'sender_id': 'sender-1',
      'receiver_id': 'receiver-1',
      'status': status,
      'amount': '200.00',
      if (billId != null) 'bill_id': billId,
    };

void main() {
  test('initial-load failure retries with the server amount string intact',
      () async {
    final gateway = FakeGateway()
      ..details.addAll(['offline', _detail('PENDING')]);
    final controller = ChatTransferDetailController(
      gateway: gateway,
      transferId: 'transfer-1',
      viewerId: 'receiver-1',
    );
    addTearDown(() async {
      controller.dispose();
      await gateway.close();
    });

    await controller.load();
    expect(controller.state.phase, ChatTransferDetailPhase.failed);
    expect(controller.state.message, '转账状态查询失败，请稍后重试');

    await controller.retry();
    expect(controller.state.phase, ChatTransferDetailPhase.ready);
    expect(controller.state.detail?['amount'], '200.00');
    expect(gateway.detailCalls, 2);
  });

  for (final action in <({
    String name,
    Future<void> Function(ChatTransferDetailController) run,
    List<Object?> Function(FakeGateway) results,
    String status
  })>[
    (
      name: 'accepted',
      run: (controller) => controller.accept(),
      results: (gateway) => gateway.acceptResults,
      status: 'ACCEPTED'
    ),
    (
      name: 'declined',
      run: (controller) => controller.decline(),
      results: (gateway) => gateway.declineResults,
      status: 'DECLINED'
    ),
  ]) {
    test('${action.name} success remains settled when detail refresh fails',
        () async {
      final gateway = FakeGateway()..details.add(_detail('PENDING'));
      action.results(gateway).add(_detail(action.status));
      gateway.details.add('refresh offline');
      var settled = 0;
      final controller = ChatTransferDetailController(
        gateway: gateway,
        transferId: 'transfer-1',
        viewerId: 'receiver-1',
        onSettled: () => settled++,
      );
      addTearDown(() async {
        controller.dispose();
        await gateway.close();
      });

      await controller.load();
      await action.run(controller);

      expect(controller.state.phase, ChatTransferDetailPhase.ready);
      expect(controller.state.detail?['status'], action.status);
      expect(controller.state.detail?['bill_id'], isNull,
          reason: 'the controller never invents an unavailable bill id');
      expect(controller.state.message, '详情更新失败，请稍后重试');
      expect(settled, 1);
    });
  }

  test('duplicate accept shares one in-flight authoritative operation',
      () async {
    final heldAccept = Completer<Map<String, dynamic>>();
    final gateway = FakeGateway()
      ..details
          .addAll([_detail('PENDING'), _detail('ACCEPTED', billId: 'bill-1')])
      ..acceptResults.add(heldAccept.future);
    final controller = ChatTransferDetailController(
      gateway: gateway,
      transferId: 'transfer-1',
      viewerId: 'receiver-1',
    );
    addTearDown(() async {
      if (!heldAccept.isCompleted) heldAccept.complete(_detail('ACCEPTED'));
      controller.dispose();
      await gateway.close();
    });

    await controller.load();
    final first = controller.accept();
    final duplicate = controller.accept();
    expect(identical(first, duplicate), isTrue);
    expect(gateway.acceptCalls, 1);
    heldAccept.complete(_detail('ACCEPTED', billId: 'bill-1'));
    await first;
    expect(gateway.acceptCalls, 1);
  });

  test('held action after account invalidation never refills or settles',
      () async {
    final heldAccept = Completer<Map<String, dynamic>>();
    final gateway = FakeGateway()
      ..details.add(_detail('PENDING'))
      ..acceptResults.add(heldAccept.future);
    var settled = 0;
    final controller = ChatTransferDetailController(
      gateway: gateway,
      transferId: 'transfer-1',
      viewerId: 'receiver-1',
      onSettled: () => settled++,
    );
    addTearDown(() async {
      if (!heldAccept.isCompleted) heldAccept.complete(_detail('ACCEPTED'));
      controller.dispose();
      await gateway.close();
    });

    await controller.load();
    final action = controller.accept();
    expect(gateway.acceptCalls, 1);
    gateway.invalidate();
    await Future<void>.delayed(Duration.zero);
    heldAccept.complete(_detail('ACCEPTED', billId: 'bill-1'));
    await action;

    expect(controller.state.phase, ChatTransferDetailPhase.ended);
    expect(controller.state.detail, isNull);
    expect(settled, 0);
    expect(gateway.detailCalls, 1);
  });
  test(
      'held accept ignores read retries until the authoritative action settles',
      () async {
    final heldAccept = Completer<Map<String, dynamic>>();
    final gateway = FakeGateway()
      ..details
          .addAll([_detail('PENDING'), _detail('ACCEPTED', billId: 'bill-1')])
      ..acceptResults.add(heldAccept.future);
    final controller = ChatTransferDetailController(
      gateway: gateway,
      transferId: 'transfer-1',
      viewerId: 'receiver-1',
    );
    addTearDown(() async {
      if (!heldAccept.isCompleted) heldAccept.complete(_detail('ACCEPTED'));
      controller.dispose();
      await gateway.close();
    });

    await controller.load();
    final action = controller.accept();
    final retry = controller.retry();
    expect(gateway.detailCalls, 1);
    heldAccept.complete(_detail('ACCEPTED', billId: 'bill-1'));
    await Future.wait([action, retry]);

    expect(controller.state.detail?['status'], 'ACCEPTED');
    expect(controller.state.detail?['bill_id'], 'bill-1');
    expect(gateway.detailCalls, 2);
  });

  test(
      'settled callback failure does not turn an accepted transfer into failure',
      () async {
    final gateway = FakeGateway()
      ..details
          .addAll([_detail('PENDING'), _detail('ACCEPTED', billId: 'bill-1')])
      ..acceptResults.add(_detail('ACCEPTED', billId: 'bill-1'));
    final originalOnError = FlutterError.onError;
    var reports = 0;
    FlutterError.onError = (_) => reports++;
    final controller = ChatTransferDetailController(
      gateway: gateway,
      transferId: 'transfer-1',
      viewerId: 'receiver-1',
      onSettled: () => throw StateError('observer unavailable'),
    );
    addTearDown(() async {
      FlutterError.onError = originalOnError;
      controller.dispose();
      await gateway.close();
    });

    await controller.load();
    await controller.accept();

    expect(reports, 1);
    expect(controller.state.phase, ChatTransferDetailPhase.ready);
    expect(controller.state.detail?['status'], 'ACCEPTED');
    expect(controller.state.message, isNull);
  });

  test('same-epoch invalidation clears held reads and rejects new requests',
      () async {
    final heldDetail = Completer<Map<String, dynamic>>();
    final gateway = FakeGateway()..details.add(heldDetail.future);
    final controller = ChatTransferDetailController(
      gateway: gateway,
      transferId: 'transfer-1',
      viewerId: 'receiver-1',
    );
    addTearDown(() async {
      if (!heldDetail.isCompleted) heldDetail.complete(_detail('PENDING'));
      controller.dispose();
      await gateway.close();
    });

    final load = controller.load();
    gateway.invalidate(advanceEpoch: false);
    await Future<void>.delayed(Duration.zero);
    heldDetail.complete(_detail('PENDING'));
    await load;
    await controller.retry();

    expect(controller.state.phase, ChatTransferDetailPhase.ended);
    expect(controller.state.detail, isNull);
    expect(gateway.detailCalls, 1);
  });

  test('disposing during a held action never settles or refreshes', () async {
    final heldAccept = Completer<Map<String, dynamic>>();
    final gateway = FakeGateway()
      ..details.add(_detail('PENDING'))
      ..acceptResults.add(heldAccept.future);
    var settled = 0;
    final controller = ChatTransferDetailController(
      gateway: gateway,
      transferId: 'transfer-1',
      viewerId: 'receiver-1',
      onSettled: () => settled++,
    );
    addTearDown(() async {
      if (!heldAccept.isCompleted) heldAccept.complete(_detail('ACCEPTED'));
      controller.dispose();
      await gateway.close();
    });

    await controller.load();
    final action = controller.accept();
    controller.dispose();
    heldAccept.complete(_detail('ACCEPTED', billId: 'bill-1'));
    await action;

    expect(controller.state.phase, ChatTransferDetailPhase.ended);
    expect(controller.state.detail, isNull);
    expect(settled, 0);
    expect(gateway.detailCalls, 1);
  });

  test('a pending transfer cannot be accepted by its sender', () async {
    final gateway = FakeGateway()..details.add(_detail('PENDING'));
    final controller = ChatTransferDetailController(
      gateway: gateway,
      transferId: 'transfer-1',
      viewerId: 'sender-1',
    );
    addTearDown(() async {
      controller.dispose();
      await gateway.close();
    });

    await controller.load();
    await controller.accept();

    expect(gateway.acceptCalls, 0);
    expect(controller.state.detail?['status'], 'PENDING');
  });
}
