import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/finance/wallet_entry_store.dart';
import 'package:liuhetong_mobile/features/wallet/manual_operation_store.dart';
import 'package:liuhetong_mobile/features/wallet/manual_wallet_page.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'manual_wallet_api_test.dart' as fixtures;
import 'manual_wallet_flow_test.dart' as flow;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WalletEntryStores.disposeAll();
  });

  Future<Widget> walletFor(String status,
      {ManualWalletSection section = ManualWalletSection.overview,
      List<Map<String, dynamic>> history = const [],
      Brightness brightness = Brightness.light,
      void Function()? onCreate}) async {
    final official = fixtures.syntheticTronAddress();
    final api = await flow.client((request) async {
      final path = request.url.path;
      if (path.endsWith('/binding')) {
        return flow.json({
          ...fixtures.binding,
          'status': status,
          'id': status == 'ACTIVE' ? 'binding' : null,
          'masked_address': status == 'ACTIVE' ? 'T***123' : null,
          'pending_id': status == 'PENDING' ? 'pending-binding' : null,
        });
      }
      if (path.endsWith('/requests/mine')) {
        return flow.json({'items': history});
      }
      if (path.endsWith('/fx/rate')) {
        return flow.json({'rate': '7.10', 'stale': false});
      }
      if (path.endsWith('/official-payment')) {
        return flow.json(
            {'network': 'TRON', 'address': official, 'config_version': 'v1'});
      }
      if (request.method == 'POST') {
        onCreate?.call();
        return flow.json({
          'id': 'new-1',
          'amount_usdt': '20.000000',
          'status': 'SUBMITTED',
          'processing_stage': 'WAITING_PAYMENT',
          'expires_at': '2030-01-01T02:00:00Z',
          'official_payment': {
            'network': 'TRON',
            'address': official,
            'config_version': 'v1'
          }
        });
      }
      return flow.json({});
    }, capabilities: {
      'caibi_pricing_version': 'caibi-cny-v1',
      'funding_enabled': true,
    });
    return CupertinoApp(
        theme: CupertinoThemeData(brightness: brightness),
        home: ManualWalletPage(client: api, section: section));
  }

  for (final status in ['UNBOUND', 'PENDING']) {
    testWidgets('$status cannot open a new CNY recharge', (tester) async {
      var creates = 0;
      await tester
          .pumpWidget(await walletFor(status, onCreate: () => creates++));
      await tester.pumpAndSettle();

      final recharge = tester.widget<CupertinoButton>(
          find.byKey(const Key('manual-deposit-open')));
      expect(recharge.onPressed, isNull);
      expect(find.byKey(const Key('manual-wallet-binding-warning')),
          findsOneWidget);
      expect(
          find.byKey(const Key('manual-wallet-binding-card')), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.exclamationmark_triangle_fill),
          findsOneWidget);
      final balance = tester
          .widget<Text>(find.byKey(const Key('manual-wallet-balance-value')));
      expect(balance.style?.fontSize, WeChatTypography.brand);
      expect(creates, 0);
    });
    testWidgets('$status direct recharge route cannot submit a new request',
        (tester) async {
      var creates = 0;
      await tester.pumpWidget(await walletFor(status,
          section: ManualWalletSection.deposit, onCreate: () => creates++));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<CupertinoButton>(
                  find.byKey(const Key('manual-recharge-submit')))
              .onPressed,
          isNull);
      expect(creates, 0);
    });
  }

  testWidgets('binding load never enables a new recharge shortcut',
      (tester) async {
    final bindingGate = Completer<void>();
    var creates = 0;
    final api = await flow.client((request) async {
      if (request.url.path.endsWith('/binding')) {
        await bindingGate.future;
        return flow.json(fixtures.binding);
      }
      if (request.url.path.endsWith('/requests/mine')) {
        return flow.json({'items': []});
      }
      if (request.method == 'POST') creates++;
      return flow.json({});
    }, capabilities: {'caibi_pricing_version': 'caibi-cny-v1'});
    await tester.pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pump();
    final recharge = find.byKey(const Key('manual-deposit-open'));
    if (recharge.evaluate().isNotEmpty) {
      expect(tester.widget<CupertinoButton>(recharge).onPressed, isNull);
    }
    expect(creates, 0);
    bindingGate.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<CupertinoButton>(recharge).onPressed, isNotNull);
  });

  testWidgets('active binding can create a new recharge request',
      (tester) async {
    var creates = 0;
    await tester.pumpWidget(await walletFor('ACTIVE',
        section: ManualWalletSection.deposit, onCreate: () => creates++));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<CupertinoButton>(
                find.byKey(const Key('manual-recharge-submit')))
            .onPressed,
        isNotNull);
    await tester.enterText(
        find.byKey(const Key('manual-deposit-amount')), '20');
    await flow.tap(tester, find.byKey(const Key('manual-recharge-submit')));
    expect(creates, 1);
    expect(find.byKey(const Key('recharge-payment-new-1')), findsOneWidget);
  });

  testWidgets('wallet balance and binding cards follow dark surface tokens',
      (tester) async {
    await tester
        .pumpWidget(await walletFor('UNBOUND', brightness: Brightness.dark));
    await tester.pumpAndSettle();

    for (final key in [
      'manual-wallet-summary',
      'manual-wallet-binding-card',
    ]) {
      final finder = find.byKey(Key(key));
      final card = tester.widget<Container>(finder);
      expect((card.decoration as BoxDecoration).color,
          WeChatColors.elevatedSurface(tester.element(finder)));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('unbound wallet can inspect old recharge without creating one',
      (tester) async {
    var creates = 0;
    await tester.pumpWidget(await walletFor('UNBOUND',
        history: [
          {'id': 'old-1', 'amount_usdt': '10.000000', 'status': 'CREDITED'}
        ],
        onCreate: () => creates++));
    await tester.pumpAndSettle();

    await flow.tap(
        tester, find.byKey(const Key('manual-recharge-history-open')));
    expect(find.text('old-1'), findsWidgets);
    expect(
        tester
            .widget<CupertinoButton>(
                find.byKey(const Key('manual-recharge-submit')))
            .onPressed,
        isNull);
    expect(creates, 0);
  });

  testWidgets('an existing uncertain recharge keeps its original retry key',
      (tester) async {
    final submittedKeys = <String?>[];
    var officialPaymentCalls = 0;
    final api = await flow.client((request) async {
      if (request.url.path.endsWith('/binding')) {
        return flow.json({
          ...fixtures.binding,
          'status': 'UNBOUND',
          'id': null,
          'masked_address': null,
        });
      }
      if (request.url.path.endsWith('/requests/mine')) {
        return flow.json({'items': []});
      }
      if (request.url.path.endsWith('/fx/rate')) {
        return flow.json({'rate': '7.10', 'stale': false});
      }
      if (request.url.path.endsWith('/official-payment')) {
        officialPaymentCalls++;
        return flow.json({});
      }
      if (request.method == 'POST') {
        submittedKeys.add(request.headers['Idempotency-Key']);
        return flow.json({
          'id': 'replayed-1',
          'amount_usdt': '10.000000',
          'status': 'SUBMITTED'
        });
      }
      return flow.json({});
    }, capabilities: {'caibi_pricing_version': 'caibi-cny-v1'});
    final store = ManualOperationStore(api);
    await store.initialize();
    final original = await store.begin('recharge', {'amount': '10.000000'});
    await tester.pumpWidget(CupertinoApp(
        home: ManualWalletPage(
            client: api, section: ManualWalletSection.deposit)));
    await tester.pumpAndSettle();

    final retry = tester.widget<CupertinoButton>(
        find.byKey(const Key('manual-recharge-submit')));
    expect(retry.onPressed, isNotNull);
    expect(find.text('重试同一申请'), findsOneWidget);
    expect((await store.read('recharge'))?['key'], original['key']);
    await flow.tap(tester, find.byKey(const Key('manual-recharge-submit')));
    expect(submittedKeys, [original['key']]);
    expect(officialPaymentCalls, 0, reason: '同键回放不得因当前官方收款配置不可用而失败');
  });
}
