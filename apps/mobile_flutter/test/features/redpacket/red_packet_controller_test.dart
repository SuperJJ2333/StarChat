import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_auth_contracts.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/redpacket/red_packet_controller.dart';

void main() {
  test('disposed held load never publishes detail', () async {
    final api = _Api();
    final controller = RedPacketController(api);
    final load = controller.load('p');
    controller.dispose();
    api.detail.complete({'id': 'p'});
    await load;
    expect(controller.detail, isNull);
  });
  test('same epoch invalidation rejects a late load', () async {
    final api = _Api();
    final controller = RedPacketController(api);
    final load = controller.load('p');
    api.invalidations
        .add(const BusinessSessionInvalidation(epoch: 1, code: 'logout'));
    api.detail.complete({'id': 'p'});
    await load;
    expect(controller.detail, isNull);
    expect(controller.error, '会话已结束');
    controller.dispose();
  });
  test('epoch change rejects a late load', () async {
    final api = _Api();
    final controller = RedPacketController(api);
    final load = controller.load('p');
    api.epoch++;
    api.detail.complete({'id': 'p'});
    await load;
    expect(controller.detail, isNull);
    controller.dispose();
  });
  test('claim success returns amount when reload fails', () async {
    final api = _Api();
    api.claimResult = {'amount': '8.88'};
    final controller = RedPacketController(api);
    final claim = controller.claim('p');
    await Future<void>.microtask(() {});
    api.detail.completeError(StateError('reload'));
    expect(await claim, '8.88');
    expect(controller.error, isNotNull);
    controller.dispose();
  });
  test('held claim after epoch rejects old account amount without detail read',
      () async {
    final api = _Api();
    final controller = RedPacketController(api);
    final claim = controller.claim('p');
    expect(api.claimCalls, 1);
    api.epoch++;
    api.claim.complete({'amount': '8.88'});
    await expectLater(
        claim,
        throwsA(
            isA<StateError>().having((e) => e.message, 'message', '会话已结束')));
    expect(api.detailCalls, 0);
    controller.dispose();
  });
  test('epoch drift clears an existing detail and loading state', () async {
    final api = _Api();
    final controller = RedPacketController(api);
    final first = controller.load('p');
    api.detail.complete({'id': 'old'});
    await first;
    expect(controller.detail, isNotNull);
    api.detail = Completer<Map<String, dynamic>>();
    final second = controller.load('p');
    api.epoch++;
    api.detail.complete({'id': 'late'});
    await second;
    expect(controller.detail, isNull);
    expect(controller.loading, isFalse);
    expect(controller.error, '会话已结束');
    controller.dispose();
  });
}

final class _Api implements RedPacketViewGateway, BusinessSessionMonitor {
  _Api() {
    addTearDown(() => invalidations.close());
  }

  final invalidations =
      StreamController<BusinessSessionInvalidation>.broadcast(sync: true);
  Completer<Map<String, dynamic>> detail = Completer<Map<String, dynamic>>();
  final claim = Completer<Map<String, dynamic>>();
  Map<String, dynamic> claimResult = const {};
  int detailCalls = 0;
  int claimCalls = 0;
  int epoch = 1;
  @override
  int get sessionEpoch => epoch;
  @override
  Stream<BusinessSessionInvalidation> get sessionInvalidations =>
      invalidations.stream;
  @override
  Future<void> checkSessionValidity() async {}
  @override
  Future<Map<String, dynamic>> redPacketDetail(String id) {
    detailCalls++;
    return detail.future;
  }

  @override
  Future<Map<String, dynamic>> claimRedPacket(String id) {
    claimCalls++;
    return claimResult.isEmpty ? claim.future : Future.value(claimResult);
  }

  @override
  Future<List<ContactSummary>> listContacts() async => const [];
}
