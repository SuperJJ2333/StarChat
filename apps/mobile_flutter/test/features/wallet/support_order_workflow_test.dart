import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/finance/wallet_entry_store.dart';
import 'package:liuhetong_mobile/features/wallet/manual_wallet_page.dart';
import 'package:liuhetong_mobile/features/wallet/manual_wallet_api.dart';
import 'package:liuhetong_mobile/features/wallet/manual_payout_status_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'manual_wallet_api_test.dart' as fixtures;
import 'manual_wallet_flow_test.dart' as flow;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WalletEntryStores.disposeAll();
  });
  test('payout final settlement survives status cache serialization', () {
    final value = ManualPayout.fromJson({
      ...fixtures.payout,
      'final_receive': '12.345678',
      'final_rate': '7.12',
      'expires_at': '2030-01-01T02:00:00Z',
      'processing_stage': 'NEEDS_REVIEW',
    });
    final snapshot = ManualPayoutStatusStore.encode(value);
    expect(snapshot['final_receive'], '12.345678');
    expect(snapshot['processing_stage'], 'NEEDS_REVIEW');
  });
  testWidgets(
      'amount first, durable payment step, evidence never means credited',
      (tester) async {
    Map<String, dynamic>? order;
    final evidenceKeys = <String?>[];
    final official = fixtures.syntheticTronAddress();
    final api = await flow.client((request) async {
      final path = request.url.path;
      if (path.endsWith('/fx/rate')) return flow.json({'rate': '7.10'});
      if (path.endsWith('/official-payment')) {
        return flow.json(
            {'network': 'TRON', 'address': official, 'config_version': 'v1'});
      }
      if (path.endsWith('/requests/mine')) {
        return flow.json({
          'items': [if (order != null) order]
        });
      }
      if (path.endsWith('/evidence')) {
        evidenceKeys.add(request.headers['Idempotency-Key']);
        expect(request.headers['Idempotency-Key'], isNotEmpty);
        order = {
          ...order!,
          'processing_stage': 'NEEDS_REVIEW',
          'evidence_txid': 'a' * 64
        };
        if (evidenceKeys.length == 1) throw TimeoutException('lost reply');
        return flow.json(order!);
      }
      if (path.endsWith('/requests') && request.method == 'POST') {
        order = {
          'id': 'r1',
          'amount_usdt': '20.000000',
          'status': 'SUBMITTED',
          'processing_stage': 'WAITING_PAYMENT',
          'expires_at': '2030-01-01T02:00:00Z',
          'official_payment': {
            'network': 'TRON',
            'address': official,
            'config_version': 'v1'
          }
        };
        return flow.json(order!);
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
    expect(find.text('官方客服'), findsNothing);
    expect(find.text('收款地址'), findsNothing);
    expect(
        tester
            .widget<CupertinoTextField>(
                find.byKey(const Key('manual-deposit-amount')))
            .keyboardType,
        const TextInputType.numberWithOptions(decimal: true));
    await tester.enterText(
        find.byKey(const Key('manual-deposit-amount')), '20');
    await flow.tap(tester, find.byKey(const Key('manual-recharge-submit')));
    expect(find.byKey(const Key('recharge-payment-r1')), findsOneWidget);
    expect(find.byKey(const Key('manual-deposit-amount')), findsNothing);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    WalletEntryStores.disposeAll();
    await open();
    expect(find.byKey(const Key('recharge-payment-r1')), findsOneWidget);
    await tester.enterText(
        find.byKey(const Key('recharge-evidence-txid')), 'a' * 64);
    await flow.tap(tester, find.byKey(const Key('recharge-evidence-submit')));
    expect(find.text('已到账'), findsNothing);
    expect(find.byKey(const Key('recharge-cancel-r1')), findsNothing);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    WalletEntryStores.disposeAll();
    await open();
    await flow.tap(tester, find.byKey(const Key('recharge-evidence-submit')));
    expect(evidenceKeys.length, 2);
    expect(evidenceKeys.first, evidenceKeys.last);
    expect(find.text('已到账'), findsNothing);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
  });
  for (final stage in ['WAITING_PAYMENT', 'PAYMENT_VERIFIED', 'NEEDS_REVIEW']) {
    testWidgets(
        'expired $stage restores for review without payable address or cancellation',
        (tester) async {
      final api = await flow.client((request) async {
        if (request.url.path.endsWith('/requests/mine')) {
          return flow.json({
            'items': [
              {
                'id': 'expired',
                'amount_usdt': '20.000000',
                'status': 'SUBMITTED',
                'processing_stage': stage,
                'expires_at': '2020-01-01T02:00:00Z',
                'actual_received_usdt': '19.500000',
                'final_caibi_amount': '135.00',
                'final_rate': '6.923076',
                'official_payment': {
                  'network': 'TRON',
                  'address': fixtures.syntheticTronAddress(),
                  'config_version': 'v1'
                },
              }
            ]
          });
        }
        if (request.url.path.endsWith('/fx/rate')) {
          return flow.json({'rate': '7.10'});
        }
        return flow.json(fixtures.binding);
      }, capabilities: {'caibi_pricing_version': 'caibi-cny-v1'});
      await tester.pumpWidget(CupertinoApp(
          home: ManualWalletPage(
              client: api, section: ManualWalletSection.deposit)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('manual-deposit-amount')), findsNothing);
      expect(find.byKey(const Key('recharge-payment-expired')), findsNothing);
      expect(find.byKey(const Key('recharge-cancel-expired')), findsNothing);
      expect(find.text('135.00'), findsOneWidget);
      expect(find.text('已到账'), findsNothing);
      expect(find.byKey(const Key('recharge-evidence-submit')), findsOneWidget);
      await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    });
  }
}
