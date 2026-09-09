import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/wallet/manual_wallet_page.dart';
import 'package:liuhetong_mobile/features/wallet/manual_operation_store.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'manual_wallet_api_test.dart' as fixtures;
import 'manual_wallet_flow_test.dart' as flow;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final slot in ['deposit', 'payout']) {
    testWidgets('closed gate allows exact persisted $slot recovery',
        (tester) async {
      final writes = <http.Request>[];
      final api = await flow.client((request) async {
        if (request.method == 'POST') {
          writes.add(request);
          return flow
              .json(slot == 'deposit' ? fixtures.intent : fixtures.payout);
        }
        return flow.json(fixtures.binding);
      }, capabilities: {});
      final store = ManualOperationStore(api);
      await store.initialize();
      final pending = await store.begin(
          slot,
          slot == 'deposit'
              ? {'amount': '10.000000', 'version': 1}
              : {'quote_id': 'quote'});
      await tester
          .pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
      await tester.pumpAndSettle();
      await flow.tap(tester, find.text(slot == 'deposit' ? '充值' : '提现'));
      if (slot == 'payout') {
        await tester.enterText(
            find.byKey(const Key('manual-payout-otp')), '123456');
      }
      await flow.tap(
          tester,
          find.byKey(Key(slot == 'deposit'
              ? 'manual-deposit-create'
              : 'manual-payout-confirm')));
      expect(writes, hasLength(1));
      expect(writes.single.headers['Idempotency-Key'], pending['key']);
      expect((await store.read(slot))?['id'], isNotNull);
      await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    });
  }
  for (final deposits in [false, true]) {
    for (final requests in [false, true]) {
      for (final execution in [false, true]) {
        testWidgets('independent gates $deposits/$requests/$execution',
            (tester) async {
          final api = await flow
              .client((_) async => flow.json(fixtures.binding), capabilities: {
            'funding_enabled': deposits,
            'manual_payout_enabled': requests,
            'manual_payout_execution_enabled': execution,
            'conversion_enabled': false,
          });
          await tester
              .pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
          await tester.pumpAndSettle();
          await flow.tap(tester, find.text('充值'));
          expect(
              tester
                      .widget<CupertinoButton>(
                          find.byKey(const Key('manual-deposit-create')))
                      .onPressed !=
                  null,
              deposits);
          await flow.tap(tester, find.text('提现'));
          expect(
              tester
                      .widget<CupertinoButton>(
                          find.byKey(const Key('manual-quote-create')))
                      .onPressed !=
                  null,
              requests);
          expect(
              find.text(
                  execution ? '最低 10 USDT · 免手续费 · 人工处理' : '付款暂未开放，申请后等待处理'),
              findsOneWidget);
        });
      }
    }
  }
  testWidgets('missing capabilities fail closed', (tester) async {
    final api = await flow
        .client((_) async => flow.json(fixtures.binding), capabilities: {});
    await tester.pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();
    await flow.tap(tester, find.text('充值'));
    expect(
        tester
            .widget<CupertinoButton>(
                find.byKey(const Key('manual-deposit-create')))
            .onPressed,
        isNull);
    await flow.tap(tester, find.text('提现'));
    expect(
        tester
            .widget<CupertinoButton>(
                find.byKey(const Key('manual-quote-create')))
            .onPressed,
        isNull);
  });
  testWidgets(
      'disabling deposits hides payment details but retains open intent',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final capabilities = <String, dynamic>{'funding_enabled': true};
    final now = DateTime.utc(2026, 9, 7);
    final api = await flow.client(
        (r) async => flow.json(r.url.path.endsWith('/binding')
            ? fixtures.binding
            : {
                ...fixtures.intent,
                'expires_at':
                    now.add(const Duration(hours: 1)).toIso8601String(),
              }),
        capabilities: capabilities);
    await tester.pumpWidget(
        CupertinoApp(home: ManualWalletPage(client: api, clock: () => now)));
    await tester.pumpAndSettle();
    await flow.tap(tester, find.text('充值'));
    await tester.enterText(
        find.byKey(const Key('manual-deposit-amount')), '10');
    await flow.tap(tester, find.byKey(const Key('manual-deposit-create')));
    expect(find.byKey(const Key('manual-deposit-qr')), findsOneWidget);
    capabilities['funding_enabled'] = false;
    await flow.tap(tester, find.byKey(const Key('manual-refresh')));
    expect(find.byKey(const Key('manual-deposit-qr')), findsNothing);
    expect(find.text('再次充值'), findsNothing);
    expect(find.text('查看本次充值'), findsOneWidget);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
  });
}
