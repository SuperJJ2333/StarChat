import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/wallet/wallet_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
      'wallet exposes manual funding flow and removes arbitrary destination',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const CupertinoApp(home: WalletPage()));
    expect(find.byKey(const Key('wallet-manual-open')), findsOneWidget);
    expect(find.byKey(const Key('wallet-withdraw-address')), findsNothing);
  });
}
