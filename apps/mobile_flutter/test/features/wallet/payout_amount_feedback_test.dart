import 'dart:async';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:liuhetong_mobile/features/finance/wallet_entry_store.dart';
import 'package:liuhetong_mobile/features/wallet/manual_operation_store.dart';
import 'package:liuhetong_mobile/features/wallet/manual_wallet_page.dart';
import 'package:liuhetong_mobile/ui/components/wechat_toast.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'manual_wallet_api_test.dart' as fixtures;
import 'manual_wallet_flow_test.dart' as flow;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WalletEntryStores.disposeAll();
  });
  for (final snapshot in [
    {'rate': '7.12', 'stale': true},
    {'rate': '0', 'stale': false},
  ]) {
    testWidgets('unusable reference never invents points minimum $snapshot',
        (tester) async {
      final api = await flow.client((request) async => flow.json(
          request.url.path.endsWith('/fx/rate') ? snapshot : fixtures.binding));
      await tester.pumpWidget(CupertinoApp(
          home: ManualWalletPage(
              client: api, section: ManualWalletSection.payout)));
      await tester.pumpAndSettle();
      expect(find.text('最低提现 10 USDT，点钻金额以报价时汇率为准'), findsOneWidget);
      expect(find.textContaining('约需'), findsNothing);
      await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    });
  }
  for (final uncertain in [false, true]) {
    testWidgets('payout rejection recovery uncertain=$uncertain',
        (tester) async {
      final posts = <http.Request>[];
      final api = await flow.client((request) async {
        if (request.url.path.endsWith('/fx/rate')) {
          return flow.json({'rate': '7.123456', 'stale': false});
        }
        if (request.url.path.endsWith('/payout-quotes')) {
          posts.add(request);
          if (posts.length == 1) {
            if (uncertain) throw TimeoutException('lost response');
            return http.Response(
                jsonEncode({
                  'error': {
                    'code': 'WALLET_PAYOUT_AMOUNT_INVALID',
                    'message': 'WALLET_PAYOUT_AMOUNT_INVALID'
                  }
                }),
                400,
                headers: {'content-type': 'application/json'});
          }
          return flow.json({
            ...fixtures.quote,
            'funding_asset': 'CAIBI',
            'funding_amount': uncertain ? '20.00' : '80.00',
            'amount': uncertain ? '20.000000' : '80.000000'
          });
        }
        return flow.json(fixtures.binding);
      });
      await tester.pumpWidget(CupertinoApp(
          home: ManualWalletPage(
              client: api, section: ManualWalletSection.payout)));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('manual-payout-amount')), '20');
      await flow.tap(tester, find.byKey(const Key('manual-quote-create')));
      final store = ManualOperationStore(api);
      await store.initialize();
      if (!uncertain) {
        expect(await store.read('quote'), isNull);
        expect(find.byType(WeChatToast), findsOneWidget);
        expect(find.textContaining('最低提现 10 USDT'), findsWidgets);
        expect(find.textContaining('71.24 点钻'), findsWidgets);
      } else {
        expect((await store.read('quote'))?['amount'], '20.000000');
      }
      await tester.enterText(
          find.byKey(const Key('manual-payout-amount')), '80');
      await flow.tap(tester, find.byKey(const Key('manual-quote-create')));
      expect(posts, hasLength(2));
      expect(jsonDecode(posts.last.body)['amount'],
          uncertain ? '20.000000' : '80.000000');
      expect(
          posts.last.headers['Idempotency-Key'],
          uncertain
              ? posts.first.headers['Idempotency-Key']
              : isNot(posts.first.headers['Idempotency-Key']));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    });
  }
}
