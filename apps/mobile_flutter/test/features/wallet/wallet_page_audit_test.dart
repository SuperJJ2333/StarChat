import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/wallet/manual_operation_store.dart';
import 'package:liuhetong_mobile/features/wallet/manual_wallet_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'manual_wallet_api_test.dart' as fixtures;
import 'manual_wallet_flow_test.dart' as flow;
export 'manual_wallet_api_test.dart' show MemoryStore;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
      'acknowledged manual withdrawal survives failed status and restart',
      (tester) async {
    var writes = 0;
    final api = await flow.client((request) async {
      if (request.method == 'POST') {
        writes++;
        return flow.json(fixtures.payout);
      }
      if (request.url.path.endsWith('/binding')) {
        return flow.json(fixtures.binding);
      }
      throw Exception('status unavailable');
    });
    final store = ManualOperationStore(api);
    await store.initialize();
    await store.begin('payout', {'quote_id': 'quote', 'id': 'order'});
    for (var i = 0; i < 2; i++) {
      await tester
          .pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
      await tester.pumpAndSettle();
      await flow.tap(tester, find.text('提现'));
      expect(find.byKey(const Key('manual-payout-confirm')), findsNothing);
      await flow.tap(tester, find.byKey(const Key('manual-refresh')));
      await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    }
    expect(writes, 0);
  });

  testWidgets('manual payout double tap sends one request', (tester) async {
    var writes = 0;
    final completion = Completer<void>();
    final api = await flow.client((request) async {
      if (request.url.path.endsWith('/binding')) {
        return flow.json(fixtures.binding);
      }
      writes++;
      await completion.future;
      return flow.json(fixtures.payout);
    });
    final store = ManualOperationStore(api);
    await store.initialize();
    await store.begin('payout', {'quote_id': 'quote'});
    await tester.pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();
    await flow.tap(tester, find.text('提现'));
    await tester.enterText(
        find.byKey(const Key('manual-payout-otp')), '654321');
    final button = find.byKey(const Key('manual-payout-confirm'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pump();
    await tester.tap(button);
    await tester.pump();
    completion.complete();
    await tester.pumpAndSettle();
    expect(writes, 1);
  });

  testWidgets(
      'leaving manual wallet during request does not touch disposed fields',
      (tester) async {
    final completion = Completer<void>();
    final api = await flow.client((request) async {
      await completion.future;
      return flow.json(fixtures.binding);
    });
    await tester.pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pump();
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    completion.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('claimed payout shows server state without cancellation action',
      (tester) async {
    final api = await flow.client((request) async => flow.json(
        request.url.path.endsWith('/binding')
            ? fixtures.binding
            : {...fixtures.payout, 'status': 'CLAIMED'}));
    final store = ManualOperationStore(api);
    await store.initialize();
    await store.begin('payout', {'quote_id': 'quote', 'id': 'order'});
    await tester.pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();
    await flow.tap(tester, find.text('提现'));
    expect(find.text('状态：claimed'), findsOneWidget);
    expect(find.text('取消提现申请'), findsNothing);
    expect(find.byKey(const Key('manual-payout-confirm')), findsNothing);
  });
}
