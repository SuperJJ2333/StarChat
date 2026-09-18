import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/features/finance/wallet_entry_store.dart';
import 'package:liuhetong_mobile/features/wallet/manual_operation_store.dart';
import 'package:liuhetong_mobile/features/wallet/manual_wallet_page.dart';
import 'manual_wallet_api_test.dart' as fixtures;
import 'manual_wallet_flow_test.dart' as flow;

http.Response rejected(String code) => http.Response(
    jsonEncode({
      'error': {'code': code, 'message': '请求已拒绝'}
    }),
    409,
    headers: {'content-type': 'application/json'});

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 进入态 Store 是进程内共享的（键 = 钱包作用域 + 会话 epoch）：用例之间必须
    // 清空，否则上一个用例的缓存会泄漏到下一个用例的「首次进入」断言。
    WalletEntryStores.disposeAll();
  });

  for (final code in const [
    'WALLET_PAYOUT_QUOTE_EXPIRED',
    'WALLET_PAYOUT_QUOTE_CHANGED',
  ]) {
    testWidgets('$code clears a recovered payout and permits a fresh quote',
        (tester) async {
      final api = await flow.client((r) async {
        if (r.url.path.endsWith('/binding')) {
          return flow.json(fixtures.binding);
        }
        if (r.url.path.contains('/payout-quotes/')) {
          return flow.json(fixtures.quote);
        }
        return rejected(code);
      });
      final store = ManualOperationStore(api);
      await store.initialize();
      await store.begin('payout', {'quote_id': 'expired-quote'});
      await store.begin('quote', {'amount': '10.000000', 'version': 1});
      await tester
          .pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
      await tester.pumpAndSettle();
      await flow.tap(tester, find.text('查看已有提现申请'));
      await flow.tap(tester, find.byKey(const Key('manual-payout-confirm')));
      expect(await store.read('payout'), isNull);
      expect(await store.read('quote'), isNull);
      await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
      await tester.pumpWidget(CupertinoApp(
          home: ManualWalletPage(
              client: api, section: ManualWalletSection.payout)));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<CupertinoTextField>(
                  find.byKey(const Key('manual-payout-amount')))
              .enabled,
          isTrue);
    });
  }

  testWidgets('unknown recovered payout failure retains its original key',
      (tester) async {
    final api = await flow.client((request) async {
      if (request.url.path.endsWith('/binding')) {
        return flow.json(fixtures.binding);
      }
      if (request.url.path.contains('/payout-quotes/')) {
        return flow.json(fixtures.quote);
      }
      throw Exception('offline');
    });
    final store = ManualOperationStore(api);
    await store.initialize();
    final original = await store.begin('payout', {'quote_id': 'quote'});
    await store.begin('quote', {'amount': '10.000000', 'version': 1});
    await tester.pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();
    await flow.tap(tester, find.text('查看已有提现申请'));
    await flow.tap(tester, find.byKey(const Key('manual-payout-confirm')));
    expect((await store.read('payout'))?['key'], original['key']);
    expect((await store.read('quote'))?['amount'], '10.000000');
  });

  testWidgets(
      'expired recovered quote after PIN is required clears both records',
      (tester) async {
    final api = await flow.client((request) async {
      if (request.url.path.endsWith('/binding')) {
        return flow.json(fixtures.binding);
      }
      if (request.url.path.contains('/payout-quotes/')) {
        return flow.json(fixtures.quote);
      }
      return rejected('PAYMENT_PIN_REQUIRED');
    });
    final store = ManualOperationStore(api);
    await store.initialize();
    await store.begin('payout', {'quote_id': 'quote'});
    await store.begin('quote', {'amount': '10.000000', 'version': 1});
    await tester.pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();
    await flow.tap(tester, find.text('查看已有提现申请'));
    await tester.enterText(
        find.byKey(const Key('manual-payout-otp')), '123456');
    await flow.tap(tester, find.byKey(const Key('manual-payout-confirm')));
    expect(await store.read('payout'), isNull);
    expect(await store.read('quote'), isNull);
  });

  testWidgets('expired new quote draft is discarded when reopening payout',
      (tester) async {
    final api = await flow.client((request) async {
      if (request.url.path.endsWith('/binding')) {
        return flow.json(fixtures.binding);
      }
      if (request.url.path.contains('/payout-quotes/')) {
        return flow.json(fixtures.quote);
      }
      throw StateError('Unexpected request');
    });
    final store = ManualOperationStore(api);
    await store.initialize();
    await store.begin('quote', {'id': 'quote', 'amount': '10.000000'});
    await tester.pumpWidget(CupertinoApp(
        home: ManualWalletPage(
            client: api, section: ManualWalletSection.payout)));
    await tester.pumpAndSettle();
    expect(await store.read('quote'), isNull);
    expect(await store.read('payout'), isNull);
  });

  testWidgets('binding version rejection permits refreshed deposit request',
      (tester) async {
    final api = await flow.client((r) async {
      if (r.url.path.endsWith('/binding')) {
        return flow.json({...fixtures.binding, 'version': 2});
      }
      if (r.url.path.endsWith('/current')) return flow.json({'intent': null});
      return rejected('WALLET_BINDING_VERSION_CONFLICT');
    });
    final store = ManualOperationStore(api);
    await store.initialize();
    await store.begin('deposit', {'amount': '10.000000', 'version': 1});
    await tester.pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();
    await flow.tap(tester, find.text('充值'));
    await flow.tap(tester, find.byKey(const Key('manual-deposit-create')));
    expect(await store.read('deposit'), isNull);
    expect(
        tester
            .widget<CupertinoTextField>(
                find.byKey(const Key('manual-deposit-amount')))
            .enabled,
        isTrue);
  });

  testWidgets('expired binding confirmation can create a new challenge',
      (tester) async {
    final api = await flow.client((r) async {
      if (r.url.path.endsWith('/binding')) {
        return flow
            .json({...fixtures.binding, 'status': 'UNBOUND', 'version': 0});
      }
      if (r.url.path.endsWith('/challenges')) {
        return flow.json(fixtures.challenge);
      }
      return rejected('WALLET_CHALLENGE_EXPIRED_OR_CONSUMED');
    });
    await tester.pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();
    await flow.openBinding(tester);
    await tester.enterText(
        find.byKey(const Key('manual-binding-address')), 'T${'2' * 33}');
    await flow.tap(tester, find.byKey(const Key('manual-challenge')));
    await tester.scrollUntilVisible(
        find.byKey(const Key('manual-binding-signature')), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(
        find.byKey(const Key('manual-binding-signature')), 'signature');
    await tester.scrollUntilVisible(
        find.byKey(const Key('manual-binding-otp')), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(
        find.byKey(const Key('manual-binding-otp')), '123456');
    await flow.tap(tester, find.byKey(const Key('manual-binding-confirm')));
    final store = ManualOperationStore(api);
    await store.initialize();
    expect(await store.read('binding'), isNull);
  });

  testWidgets(
      'deposit QR becomes unavailable at deadline without manual refresh',
      (tester) async {
    var now = DateTime.utc(2026, 9, 7);
    final api =
        await flow.client((r) async => flow.json(r.url.path.endsWith('/binding')
            ? fixtures.binding
            : {
                ...fixtures.intent,
                'expires_at':
                    now.add(const Duration(seconds: 2)).toIso8601String()
              }));
    await tester.pumpWidget(
        CupertinoApp(home: ManualWalletPage(client: api, clock: () => now)));
    await tester.pumpAndSettle();
    await flow.tap(tester, find.text('充值'));
    await tester.enterText(
        find.byKey(const Key('manual-deposit-amount')), '10');
    await flow.tap(tester, find.byKey(const Key('manual-deposit-create')));
    await tester.scrollUntilVisible(
        find.byKey(const Key('manual-deposit-qr')), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.byKey(const Key('manual-deposit-qr')), findsOneWidget);
    now = now.add(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    expect(find.byKey(const Key('manual-deposit-qr')), findsNothing);
    expect(find.byKey(const Key('manual-official-copy')), findsNothing);
    expect(find.textContaining('申请已过期'), findsOneWidget);
    final warning = tester.widget<Text>(find.textContaining('申请已过期'));
    expect(
        warning.style!.color,
        CupertinoColors.systemRed
            .resolveFrom(tester.element(find.textContaining('申请已过期'))));
    expect(find.byIcon(CupertinoIcons.exclamationmark_triangle_fill),
        findsWidgets);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
  });
}
