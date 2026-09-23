import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/finance/wallet_entry_snapshot_store.dart';
import 'package:liuhetong_mobile/features/finance/wallet_entry_store.dart';
import 'package:liuhetong_mobile/features/ledger/ledger_pages.dart';
import 'package:liuhetong_mobile/features/wallet/manual_wallet_page.dart';
import 'package:liuhetong_mobile/features/wallet/wallet_history_page.dart';
import 'package:liuhetong_mobile/features/wallet/wallet_read_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'manual_wallet_flow_test.dart' as flow;
import 'manual_wallet_api_test.dart' as fixtures;

void main() {
  test('server terminal history statuses have precise Chinese labels', () {
    expect(walletHistoryStatus('CHAIN_CONFIRMED'), '已完成');
    expect(walletHistoryStatus('FAILED_COMPENSATED'), '失败已退回');
    expect(walletHistoryStatus('CREDITED'), '已到账');
    expect(walletHistoryStatus('UNKNOWN'), '结果待核验');
    expect(formatLedgerShortTime('2026-09-22T10:05:33.123Z'),
        isNot(contains('T')));
    expect(formatLedgerShortTime('2026-09-22T10:05:33.123Z'),
        isNot(contains('.123')));
  });

  setUp(() {
    WalletEntryStores.disposeAll();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() {
    WalletEntryStores.disposeAll();
    WalletEntryStores.snapshots = null;
  });

  test('persistent projection excludes unknown and secret fields', () {
    final result = walletReadProjection('recharges', {
      'items': [
        {
          'id': 'order',
          'status': 'SUBMITTED',
          'token': 'secret',
          'official_payment': {
            'network': 'TRON',
            'address': 'test-address',
            'secret': 'never'
          },
        }
      ]
    });
    expect(jsonEncode(result), isNot(contains('secret')));
    expect(jsonEncode(result), contains('test-address'));
  });

  testWidgets(
      'cold offline history displays cached rows using the ledger component and retries',
      (tester) async {
    var online = false;
    var serverAmount = '30.000000';
    final api = await flow.client((_) async {
      if (!online) throw StateError('offline');
      return flow.json({
        'items': [
          {
            'id': 'fresh-order',
            'kind': 'deposit',
            'amount': serverAmount,
            'status': 'CREDITED',
          }
        ]
      });
    });
    final scope = await api.walletIntentScope();
    final disk = InMemoryWalletEntrySnapshotStore();
    await disk.write(
        '$scope/read/history',
        WalletEntrySnapshot(savedAt: DateTime(2026, 1, 1), data: {
          'items': [
            {
              'id': 'old-order',
              'kind': 'deposit',
              'amount': '20.000000',
              'status': 'CREDITED',
              'created_at': '2026-09-22T10:00:00Z',
            }
          ]
        }));
    WalletEntryStores.snapshots = disk;
    await tester.pumpWidget(
        CupertinoApp(home: WalletHistoryPage(client: api, scope: scope)));
    await tester.pumpAndSettle();
    expect(find.byType(LedgerRecordRow), findsOneWidget);
    expect(find.text('20.000000 USDT'), findsOneWidget);
    expect(find.text('已到账'), findsOneWidget);
    expect(find.text('显示上次记录 · 点此重试更新'), findsOneWidget);
    await tester.tap(find.text('提现'));
    await tester.pumpAndSettle();
    expect(find.byType(LedgerRecordRow), findsNothing);
    online = true;
    await tester.tap(find.text('全部'));
    await tester.tap(find.text('显示上次记录 · 点此重试更新'));
    await tester.pumpAndSettle();
    expect(find.text('30.000000 USDT'), findsOneWidget);
    expect(find.text('20.000000 USDT'), findsNothing);
    await api.clearLocalSession();
    await api.sessionStore.saveSession(
        accessToken: 'e30.eyJzdWIiOiJhbGljZSJ9.test', refreshToken: 'next');
    serverAmount = '40.000000';
    await tester.pumpWidget(
        CupertinoApp(home: WalletHistoryPage(client: api, scope: scope)));
    await tester.pumpAndSettle();
    expect(find.text('40.000000 USDT'), findsOneWidget);
    // A page for a different account cannot hydrate Alice's persisted history.
    await tester.pumpWidget(
        CupertinoApp(home: WalletHistoryPage(client: api, scope: 'bob')));
    await tester.pumpAndSettle();
    expect(find.byType(LedgerRecordRow), findsNothing);
  });

  testWidgets(
      'cold offline recharge retains order and FX but cannot expose stale payment QR',
      (tester) async {
    final api = await flow.client((_) async => throw StateError('offline'));
    final scope = await api.walletIntentScope();
    SharedPreferences.setMockInitialValues({
      'wallet.manual.v1:$scope:recharge':
          jsonEncode({'key': 'idem', 'id': 'old-order', 'amount': '20.000000'}),
    });
    final disk = InMemoryWalletEntrySnapshotStore();
    Future<void> seed(String key, Map<String, dynamic> data) => disk.write(
        key, WalletEntrySnapshot(savedAt: DateTime(2026, 1, 1), data: data));
    await seed(scope, {
      'config': {
        'caibi_pricing_version': 'caibi-cny-v1',
        'funding_enabled': true,
        'manual_payout_enabled': true,
        'manual_payout_execution_enabled': true,
        'caibi_payout_enabled': true,
      },
      'caibi_available': '88.00',
      'binding': fixtures.binding
    });
    await seed('$scope/read/recharges', {
      'items': [
        {
          'id': 'old-order',
          'amount_usdt': '20.000000',
          'status': 'SUBMITTED',
          'expires_at': '2099-01-01T00:00:00Z',
          'official_payment': {'network': 'TRON', 'address': 'test-address'},
        }
      ]
    });
    await seed('$scope/read/fx', {'rate': '7.20'});
    WalletEntryStores.snapshots = disk;
    await tester.pumpWidget(CupertinoApp(
        home: ManualWalletPage(
            client: api, section: ManualWalletSection.deposit)));
    await tester.pumpAndSettle();
    expect(find.text('old-order'), findsOneWidget);
    expect(find.byKey(const Key('recharge-qr-old-order')), findsNothing);
    expect(
        walletReadCache(api, scope, 'fx', () async => {}).state.data?['rate'],
        '7.20');
    expect(find.text('充值信息加载失败，请重试'), findsWidgets);
  });
}
