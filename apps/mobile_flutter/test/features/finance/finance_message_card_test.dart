import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/finance/finance_card_store.dart';
import 'package:liuhetong_mobile/features/finance/finance_message_card.dart';

void main() {
  testWidgets('transfer wrapper renders neutral unknown state without a tap',
      (tester) async {
    final store = FinanceCardStore(_Gateway());
    var taps = 0;
    await tester.pumpWidget(CupertinoApp(
      home: FinanceMessageCard(
        store: store,
        kind: FinanceCardKind.transfer,
        id: 'first',
        greeting: 'hello',
        amount: '1.00',
        isOwn: false,
        onTap: () => taps++,
      ),
    ));
    expect(find.text('状态未知'), findsOneWidget);
    await tester.tap(find.byKey(const Key('wechat-transfer-card')));
    expect(taps, 0);
    await tester.pumpWidget(CupertinoApp(
      home: FinanceMessageCard(
        store: store,
        kind: FinanceCardKind.transfer,
        id: 'second',
        greeting: 'hello',
        amount: '2.00',
        isOwn: false,
      ),
    ));
    await tester.pump();
    store.dispose();
  });

  testWidgets('held first loads do not show available finance actions',
      (tester) async {
    final gateway = _ControlledGateway();
    final store = FinanceCardStore(gateway);
    var taps = 0;
    await tester.pumpWidget(CupertinoApp(
        home: Column(children: [
      FinanceMessageCard(
          store: store,
          kind: FinanceCardKind.redPacket,
          id: 'red',
          greeting: 'hi',
          amount: '1',
          isOwn: false,
          onTap: () => taps++),
      FinanceMessageCard(
          store: store,
          kind: FinanceCardKind.transfer,
          id: 'transfer',
          greeting: 'hi',
          amount: '1',
          isOwn: false,
          onTap: () => taps++),
    ])));
    await tester.pump();
    expect(find.text('领取红包'), findsNothing);
    expect(find.text('点击收款'), findsNothing);
    await tester.tap(find.byKey(const Key('wechat-red-packet-card')));
    await tester.tap(find.byKey(const Key('wechat-transfer-card')));
    expect(taps, 0);
    expect(gateway.currentCalls, 2);
    store.dispose();
  });

  testWidgets('accepted receiver uses business amount and receiver label',
      (tester) async {
    final gateway = _ControlledGateway();
    final store = FinanceCardStore(gateway);
    await tester.pumpWidget(CupertinoApp(
        home: FinanceMessageCard(
            store: store,
            kind: FinanceCardKind.transfer,
            id: 'accepted',
            greeting: 'hi',
            amount: '999',
            isOwn: false)));
    await tester.pump();
    gateway.user.complete('receiver');
    gateway.transfer.complete({
      'id': 'accepted',
      'status': 'ACCEPTED',
      'sender_id': 'sender',
      'receiver_id': 'receiver',
      'amount': '12.34'
    });
    await tester.pump();
    await tester.pump();
    expect(find.text('12.34 点钻'), findsOneWidget);
    expect(find.text('转账已收款'), findsOneWidget);
    store.dispose();
  });

  testWidgets('failure retry issues a new request and renders success',
      (tester) async {
    final gateway = _RetryGateway();
    final store = FinanceCardStore(gateway);
    await tester.pumpWidget(CupertinoApp(
        home: FinanceMessageCard(
            store: store,
            kind: FinanceCardKind.transfer,
            id: 'retry',
            greeting: 'hi',
            amount: '1',
            isOwn: false)));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.text('重试'), findsOneWidget);
    expect(gateway.transferCalls, 1);
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump();
    expect(gateway.transferCalls, 2);
    expect(find.text('7.00 点钻'), findsOneWidget);
    store.dispose();
  });

  testWidgets('session end clears card and disables retry and tap', (tester) async {
    final gateway = _ControlledGateway(); final store = FinanceCardStore(gateway); var taps = 0;
    await tester.pumpWidget(CupertinoApp(home: FinanceMessageCard(store: store, kind: FinanceCardKind.transfer, id: 'ended', greeting: 'hi', amount: '1', isOwn: false, onTap: () => taps++)));
    await tester.pump(); gateway.invalidations.add(null); await tester.pump(); await tester.pump();
    expect(find.text('会话已结束'), findsOneWidget); expect(find.text('重试'), findsNothing);
    await tester.tap(find.byKey(const Key('wechat-transfer-card'))); expect(taps, 0); store.dispose();
  });

  testWidgets('changing id requests the new detail and rejects the old response', (tester) async {
    final gateway = _IdGateway(); final store = FinanceCardStore(gateway);
    Future<void> pump(String id) => tester.pumpWidget(CupertinoApp(home: FinanceMessageCard(store: store, kind: FinanceCardKind.transfer, id: id, greeting: 'hi', amount: '1', isOwn: false)));
    await pump('old'); await tester.pump();
    await pump('new'); await tester.pump();
    expect(gateway.ids, containsAll(['old', 'new']));
    gateway.complete('old', 'old'); await tester.pump();
    gateway.complete('new', 'new'); await tester.pump(); await tester.pump();
    expect(find.text('new 点钻'), findsOneWidget); expect(find.text('old 点钻'), findsNothing); store.dispose();
  });

  testWidgets('paused visibility stops refresh and resumed visibility restores it', (tester) async {
    final gateway = _RefreshGateway(); final store = FinanceCardStore(gateway, refreshPeriod: const Duration(seconds: 15));
    await tester.pumpWidget(CupertinoApp(home: FinanceMessageCard(store: store, kind: FinanceCardKind.transfer, id: 'life', greeting: 'hi', amount: '1', isOwn: false)));
    await tester.pump(); await tester.pump(); expect(gateway.calls, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused); await tester.pump(const Duration(seconds: 31)); expect(gateway.calls, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed); await tester.pump(); await tester.pump(const Duration(seconds: 15)); expect(gateway.calls, 2); store.dispose();
  });
}

final class _Gateway implements FinanceCardGateway {
  final invalidations = StreamController<void>.broadcast();
  @override
  int get sessionEpoch => 1;
  @override
  Stream<void> get sessionInvalidations => invalidations.stream;
  @override
  Future<String?> currentUserId() async => 'me';
  @override
  Future<Map<String, dynamic>> redPacketDetail(String id) async => {'id': id};
  @override
  Future<Map<String, dynamic>> chatTransferDetail(String id) async =>
      {'id': id};
}

final class _ControlledGateway implements FinanceCardGateway {
  final invalidations = StreamController<void>.broadcast();
  final user = Completer<String?>();
  final transfer = Completer<Map<String, dynamic>>();
  int currentCalls = 0;
  @override
  int get sessionEpoch => 1;
  @override
  Stream<void> get sessionInvalidations => invalidations.stream;
  @override
  Future<String?> currentUserId() {
    currentCalls++;
    return user.future;
  }

  @override
  Future<Map<String, dynamic>> redPacketDetail(String id) =>
      Completer<Map<String, dynamic>>().future;
  @override
  Future<Map<String, dynamic>> chatTransferDetail(String id) => transfer.future;
}

final class _RetryGateway implements FinanceCardGateway {
  final invalidations = StreamController<void>.broadcast();
  int transferCalls = 0;
  @override
  int get sessionEpoch => 1;
  @override
  Stream<void> get sessionInvalidations => invalidations.stream;
  @override
  Future<String?> currentUserId() async => 'me';
  @override
  Future<Map<String, dynamic>> redPacketDetail(String id) async => {'id': id};
  @override
  Future<Map<String, dynamic>> chatTransferDetail(String id) {
    transferCalls++;
    if (transferCalls == 1) return Future.error(StateError('offline'));
    return Future.value({
      'id': id,
      'status': 'ACCEPTED',
      'sender_id': 'sender',
      'receiver_id': 'me',
      'amount': '7.00'
    });
  }
}

final class _IdGateway implements FinanceCardGateway {
  final invalidations = StreamController<void>.broadcast(); final ids = <String>[]; final pending = <String, Completer<Map<String,dynamic>>>{};
  @override int get sessionEpoch => 1; @override Stream<void> get sessionInvalidations => invalidations.stream;
  @override Future<String?> currentUserId() async => 'me';
  @override Future<Map<String,dynamic>> redPacketDetail(String id) async => {'id':id};
  @override Future<Map<String,dynamic>> chatTransferDetail(String id) { ids.add(id); return (pending[id] ??= Completer<Map<String,dynamic>>()).future; }
  void complete(String id, String amount) => pending[id]!.complete({'id':id,'status':'ACCEPTED','sender_id':'s','receiver_id':'me','amount':amount});
}

final class _RefreshGateway implements FinanceCardGateway {
  final invalidations = StreamController<void>.broadcast(); int calls = 0;
  @override int get sessionEpoch => 1; @override Stream<void> get sessionInvalidations => invalidations.stream;
  @override Future<String?> currentUserId() async => 'me'; @override Future<Map<String,dynamic>> redPacketDetail(String id) async => {'id':id};
  @override Future<Map<String,dynamic>> chatTransferDetail(String id) async => {'id':id,'status':'PENDING','amount':'1'}..['call'] = ++calls;
}
