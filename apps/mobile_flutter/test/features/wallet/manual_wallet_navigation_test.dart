import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/finance/wallet_entry_store.dart';
import 'package:liuhetong_mobile/features/wallet/wallet_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'manual_wallet_api_test.dart' as fixtures;
import 'manual_wallet_flow_test.dart' as flow;

void main() {
  testWidgets(
      'wallet requires an authenticated API and exposes bound manual funding shortcuts',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    // 进入态 Store 是进程内共享的：清空以免上一个用例的缓存泄漏进来。
    WalletEntryStores.disposeAll();
    await tester.pumpWidget(const CupertinoApp(home: WalletPage()));
    expect(find.text('钱包暂不可用，请重新登录'), findsOneWidget);
    expect(find.byKey(const Key('wallet-withdraw-address')), findsNothing);

    final api = await flow.client((request) async => flow
        .json(request.url.path.endsWith('/binding') ? fixtures.binding : {}));
    await tester.pumpWidget(CupertinoApp(home: WalletPage(api: api)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('manual-deposit-open')), findsOneWidget);
    expect(find.byKey(const Key('manual-payout-open')), findsOneWidget);
    expect(find.byKey(const Key('wallet-withdraw-address')), findsNothing);
  });
}
