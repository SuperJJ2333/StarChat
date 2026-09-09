import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:liuhetong_mobile/features/wallet/manual_wallet_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'manual_wallet_flow_test.dart' as flow;
import 'manual_wallet_api_test.dart' as fixtures;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('compact navigation refresh and copy preserve full typed address',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final api = await flow.client(
        (_) async => flow.json({
              ...fixtures.binding,
              'address': 'T${'3' * 33}',
              'next_rebind_at': '2026-10-08T10:00:00+00:00'
            }),
        capabilities: {'user_auth_mode': 'address_only'});
    await tester.pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.byKey(const Key('manual-wallet-summary')),
            matching: find.text('已登记')),
        findsOneWidget);
    expect(find.textContaining('地址状态：'), findsNothing);
    expect(
        find.descendant(
            of: find.byKey(const Key('manual-wallet-summary')),
            matching: find.textContaining('下次可改绑')),
        findsOneWidget);
    final segments = tester.widget<CupertinoSlidingSegmentedControl<int>>(
        find.byType(CupertinoSlidingSegmentedControl<int>));
    expect(segments.children.keys.toList(), [1, 2, 0]);
    expect(
        find.descendant(
            of: find.byType(CupertinoNavigationBar),
            matching: find.byKey(const Key('manual-refresh'))),
        findsOneWidget);
    await flow.tap(tester, find.byKey(const Key('manual-current-copy')));
    expect(copied, 'T${'3' * 33}');
    await flow.tap(tester, find.byKey(const Key('manual-binding-address')));
    await tester.enterText(
        find.byKey(const Key('manual-binding-address')), 'T${'2' * 33}');
    await flow.tap(tester, find.byKey(const Key('manual-binding-copy')));
    expect(copied, 'T${'2' * 33}');
  });

  for (final deposit in [true, false]) {
    testWidgets(
        '${deposit ? 'deposit' : 'payout'} submits integer 10 as exact six-place string',
        (tester) async {
      http.Request? captured;
      final api = await flow.client((request) async {
        if (request.url.path.endsWith('/binding')) {
          return flow.json(fixtures.binding);
        }
        captured = request;
        return flow.json(deposit ? fixtures.intent : fixtures.quote);
      }, capabilities: {
        'user_auth_mode': 'address_only',
        'funding_enabled': true,
        'manual_payout_enabled': true
      });
      await tester
          .pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
      await tester.pumpAndSettle();
      await flow.tap(tester, find.text(deposit ? '充值' : '提现'));
      final field = find.byKey(
          Key(deposit ? 'manual-deposit-amount' : 'manual-payout-amount'));
      await tester.enterText(field, '10');
      await flow.tap(
          tester,
          find.byKey(
              Key(deposit ? 'manual-deposit-create' : 'manual-quote-create')));
      expect(jsonDecode(captured!.body)['amount'], '10.000000');
      expect(captured!.headers['Idempotency-Key'], isNotEmpty);
    });
  }
}
