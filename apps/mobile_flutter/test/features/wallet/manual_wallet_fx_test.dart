import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/finance/wallet_entry_store.dart';
import 'package:liuhetong_mobile/features/wallet/manual_wallet_page.dart';
import 'package:liuhetong_mobile/features/wallet/manual_operation_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'manual_wallet_api_test.dart' as fixtures;
import 'manual_wallet_flow_test.dart' as flow;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WalletEntryStores.disposeAll();
  });

  testWidgets(
      'legacy recharge cancellation uses server endpoint and retains recovery on lost reply',
      (tester) async {
    final keys = <String?>[];
    final api = await flow.client((request) async {
      if (request.url.path.endsWith('/fx/rate')) {
        return flow.json({'rate': '7.1'});
      }
      if (request.url.path.endsWith('/cancel')) {
        keys.add(request.headers['Idempotency-Key']);
        if (keys.length == 1) throw TimeoutException('lost reply');
        return flow.json({
          ...fixtures.intent,
          'status': 'CANCELLED',
          'closed_at': '2026-09-22T00:00:00Z'
        });
      }
      if (request.url.path.contains('/deposit-intents/')) {
        return flow.json(fixtures.intent);
      }
      return flow.json(fixtures.binding);
    });
    final store = ManualOperationStore(api);
    await store.initialize();
    await store.begin(
        'deposit', {'id': 'intent', 'amount': '10.000000', 'version': 1});
    await tester.pumpWidget(CupertinoApp(
        home: ManualWalletPage(
            client: api,
            section: ManualWalletSection.deposit,
            clock: () => DateTime.utc(2026, 9, 7, 9))));
    await tester.pumpAndSettle();
    await flow.tap(tester, find.byKey(const Key('manual-deposit-cancel')));
    expect((await store.read('deposit'))?['id'], 'intent');
    expect(find.byKey(const Key('manual-deposit-qr')), findsNothing);
    await flow.tap(tester, find.byKey(const Key('manual-deposit-cancel')));
    expect(keys, hasLength(2));
    expect(keys.first, keys.last);
    expect(find.text('已取消'), findsOneWidget);
    expect(find.byKey(const Key('manual-deposit-qr')), findsNothing);
    expect(find.text('取消申请不代表链上转账已撤销或退款；如已转账请联系客服核验。'), findsOneWidget);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
  });

  for (final section in [
    ManualWalletSection.deposit,
    ManualWalletSection.payout
  ]) {
    testWidgets(
        'legacy $section displays exact reference estimate as input changes',
        (tester) async {
      var fxCalls = 0;
      final api = await flow.client((request) async {
        if (request.url.path.endsWith('/fx/rate')) {
          fxCalls++;
          return flow.json({'rate': '7.123456', 'stale': false});
        }
        return flow.json(fixtures.binding);
      });
      await tester.pumpWidget(
          CupertinoApp(home: ManualWalletPage(client: api, section: section)));
      await tester.pumpAndSettle();
      final field = find.byKey(Key(section == ManualWalletSection.deposit
          ? 'manual-deposit-amount'
          : 'manual-payout-amount'));
      await tester.enterText(field, '20');
      await tester.pumpAndSettle();
      expect(
          find.text(section == ManualWalletSection.deposit
              ? '≈ 142.47 点钻'
              : '≈ 2.807626 USDT'),
          findsOneWidget);
      await tester.enterText(field, '40');
      await tester.pumpAndSettle();
      expect(
          find.text(section == ManualWalletSection.deposit
              ? '≈ 284.94 点钻'
              : '≈ 5.615252 USDT'),
          findsOneWidget);
      expect(fxCalls, 1);
      await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    });
  }

  testWidgets('missing FX endpoint clearly states unavailable without estimate',
      (tester) async {
    final api =
        await flow.client((request) async => flow.json(fixtures.binding));
    await tester.pumpWidget(CupertinoApp(
        home: ManualWalletPage(
            client: api, section: ManualWalletSection.deposit)));
    await tester.pumpAndSettle();
    expect(find.text('参考汇率暂不可用，实际结算以客服确认为准'), findsOneWidget);
    expect(find.textContaining('≈'), findsNothing);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
  });

  testWidgets(
      'uncertain recharge retry retains stored decimal and key across restart',
      (tester) async {
    final keys = <String?>[];
    var cancelled = false;
    final api = await flow.client((request) async {
      if (request.url.path.endsWith('/fx/rate')) {
        return flow.json({'rate': '7.10'});
      }
      if (request.url.path.endsWith('/recharge/official-payment')) {
        return flow.json({
          'network': 'tron-mainnet',
          'address': fixtures.syntheticTronAddress(),
          'config_version': 'v1'
        });
      }
      if (request.url.path.endsWith('/recharge/directory')) {
        return flow.json({
          'items': [
            {
              'id': 'cs',
              'enabled': true,
              'display_name': '客服',
              'cs_user_id': 'support'
            }
          ]
        });
      }
      if (request.url.path.endsWith('/recharge/requests/mine')) {
        return flow.json({
          'items': cancelled
              ? [
                  {
                    'id': 'r1',
                    'status': 'CANCELLED',
                    'amount_usdt': '20.123456'
                  }
                ]
              : []
        });
      }
      if (request.url.path.endsWith('/cancel')) {
        cancelled = true;
        throw TimeoutException('response lost');
      }
      if (request.method == 'POST') {
        keys.add(request.headers['Idempotency-Key']);
        expect(request.body, contains('20.123456'));
        if (keys.length == 1) throw TimeoutException('response lost');
        return flow.json(
            {'id': 'r1', 'status': 'SUBMITTED', 'amount_usdt': '20.123456'});
      }
      return flow.json(fixtures.binding);
    }, capabilities: {'caibi_pricing_version': 'caibi-cny-v1'});
    Future<void> open() async {
      await tester.pumpWidget(CupertinoApp(
          home: ManualWalletPage(
              client: api, section: ManualWalletSection.deposit)));
      await tester.pumpAndSettle();
    }

    await open();
    await tester.enterText(
        find.byKey(const Key('manual-deposit-amount')), '20.123456');
    await flow.tap(tester, find.byKey(const Key('manual-recharge-submit')));
    final store = ManualOperationStore(api);
    await store.initialize();
    expect((await store.read('recharge'))?['id'], isNull);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    await open();
    await flow.tap(tester, find.byKey(const Key('manual-recharge-submit')));
    expect(keys, hasLength(2));
    expect(keys.first, keys.last);
    await flow.tap(tester, find.byKey(const Key('recharge-cancel-r1')));
    expect(find.text('已取消'), findsOneWidget);
    expect(find.byKey(const Key('recharge-cancel-r1')), findsNothing);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
  });

  testWidgets(
      'CNY pricing uses manual recharge despite automatic funding closed',
      (tester) async {
    final writes = <String>[];
    final api = await flow.client((request) async {
      if (request.url.path.endsWith('/fx/rate')) {
        return flow.json({'rate': '7.10', 'stale': false});
      }
      if (request.url.path.endsWith('/recharge/official-payment')) {
        return flow.json({
          'network': 'tron-mainnet',
          'address': fixtures.syntheticTronAddress(),
          'config_version': 'v1'
        });
      }
      if (request.url.path.endsWith('/recharge/directory')) {
        return flow.json({
          'items': [
            {
              'display_name': '客服小畅',
              'cs_user_id': 'support',
              'payment_address': 'T123',
              'enabled': true
            }
          ]
        });
      }
      if (request.url.path.endsWith('/recharge/requests/mine')) {
        return flow.json({'items': []});
      }
      if (request.method == 'POST') {
        writes.add(request.url.path);
        return flow.json({
          'id': 'request-1',
          'amount_usdt': '20.000000',
          'status': 'SUBMITTED'
        });
      }
      return flow.json(fixtures.binding);
    }, capabilities: {
      'caibi_pricing_version': 'caibi-cny-v1',
      'funding_enabled': false
    });
    await tester.pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();
    await flow.openDeposit(tester);
    expect(find.text('客服小畅'), findsNothing);
    await tester.enterText(
        find.byKey(const Key('manual-deposit-amount')), '20');
    await flow.tap(tester, find.byKey(const Key('manual-recharge-submit')));
    expect(writes, ['/api/v1/recharge/requests']);
    expect(find.text('待客服处理，尚未到账'), findsOneWidget);
    expect(find.byKey(const Key('manual-deposit-qr')), findsNothing);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
  });

  for (final section in [
    ManualWalletSection.deposit,
    ManualWalletSection.payout
  ]) {
    testWidgets('$section shows stale reference once without changing funds',
        (tester) async {
      var fxCalls = 0;
      var writes = 0;
      final api = await flow.client((request) async {
        if (request.method != 'GET') writes++;
        if (request.url.path.endsWith('/fx/rate')) {
          fxCalls++;
          return flow.json({'rate': '7.123456', 'stale': true});
        }
        if (request.url.path.contains('/recharge/')) {
          return flow.json({'items': []});
        }
        return flow.json(fixtures.binding);
      }, capabilities: {'caibi_pricing_version': 'caibi-cny-v1'});
      await tester.pumpWidget(
          CupertinoApp(home: ManualWalletPage(client: api, section: section)));
      await tester.pumpAndSettle();
      expect(find.text('1 USDT ≈ ¥7.123456'), findsOneWidget);
      expect(find.text('参考汇率已过期，实际结算以客服确认为准'), findsOneWidget);
      await tester.enterText(
          find.byKey(Key(section == ManualWalletSection.deposit
              ? 'manual-deposit-amount'
              : 'manual-payout-amount')),
          '20');
      await tester.pump();
      expect(fxCalls, 1);
      expect(writes, 0);
      expect(find.textContaining('1 点钻 = 1 USDT'), findsNothing);
      await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    });
  }
}
