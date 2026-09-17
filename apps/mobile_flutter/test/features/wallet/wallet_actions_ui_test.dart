import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/wallet/manual_operation_store.dart';
import 'package:liuhetong_mobile/features/wallet/manual_wallet_page.dart';
import 'package:liuhetong_mobile/features/wallet/wallet_page.dart';
import 'package:liuhetong_mobile/ui/components/wechat_secondary_button.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'manual_wallet_api_test.dart' as fixtures;
import 'manual_wallet_flow_test.dart' as flow;

/// 绑定 fixture 本身只有 masked_address；钱包卡片的复制动作依赖完整地址。
Map<String, dynamic> boundFixture() =>
    {...fixtures.binding, 'address': fixtures.syntheticTronAddress()};

BoxDecoration decorationOf(WidgetTester tester, String label) =>
    tester
        .widget<Container>(find
            .descendant(
                of: find.widgetWithText(WeChatSecondaryButton, label),
                matching: find.byType(Container))
            .first)
        .decoration! as BoxDecoration;

Text labelOf(WidgetTester tester, String label) => tester.widget<Text>(
    find.descendant(
        of: find.widgetWithText(WeChatSecondaryButton, label),
        matching: find.text(label)));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('wallet card shows the address copy action beside the address',
      (tester) async {
    final api = await flow.client((request) async => flow.json(
        request.url.path.endsWith('/binding') ? boundFixture() : {}));
    await tester.pumpWidget(CupertinoApp(home: WalletPage(api: api)));
    await tester.pumpAndSettle();

    final copy = find.byKey(const Key('manual-current-copy'));
    final address = find.byKey(const Key('manual-wallet-bound-address'));
    expect(address, findsOneWidget);
    expect(find.text('T***123'), findsOneWidget);
    expect(copy, findsOneWidget);

    final copyCentre = tester.getCenter(copy);
    // 复制 icon 必须与钱包地址同一行，且位于地址右侧。
    expect(copyCentre.dy, closeTo(tester.getCenter(address).dy, 1.0));
    expect(copyCentre.dx, greaterThan(tester.getRect(address).right - 1.0));
    // 不得再落在「当前点钻余额」行。
    final balance = tester.getCenter(find.textContaining('当前点钻余额'));
    expect(copyCentre.dy, isNot(closeTo(balance.dy, 1.0)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('deposit page no longer offers the conversion card',
      (tester) async {
    final api = await flow.client((request) async => flow.json(
        request.url.path.endsWith('/binding') ? boundFixture() : {}));
    await tester.pumpWidget(CupertinoApp(home: WalletPage(api: api)));
    await tester.pumpAndSettle();
    await flow.openDeposit(tester);

    expect(find.text('点钻与 USDT 兑换'), findsNothing);
    expect(find.textContaining('1 USDT = 1 点钻'), findsNothing);
    expect(find.byKey(const Key('wallet-conversion-card')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('withdraw page buttons are distinguishable from plain text',
      (tester) async {
    final api = await flow.client((request) async => flow.json(
        request.url.path.endsWith('/binding') ? boundFixture() : {}));
    await tester.pumpWidget(CupertinoApp(home: WalletPage(api: api)));
    await tester.pumpAndSettle();
    await flow.openPayout(tester);

    // 「全部提现」没有背景色，必须有可见边框。
    final all = decorationOf(tester, '全部提现');
    expect(all.color, isNull);
    expect(all.border, isNotNull);
    expect((all.border! as Border).top.width, greaterThan(0));
    expect(labelOf(tester, '全部提现').style?.color, WeChatColors.brandPrimary);
    expect(tester.takeException(), isNull);
  });

  testWidgets('start-new-withdrawal button is a bordered button',
      (tester) async {
    final api = await flow.client((request) async => flow.json(
        request.url.path.endsWith('/binding')
            ? boundFixture()
            : request.url.path.contains('/payout-quotes/')
                ? fixtures.quote
                : {...fixtures.payout, 'status': 'SETTLED'}));
    final store = ManualOperationStore(api);
    await store.initialize();
    await store.begin('payout', {'quote_id': 'quote', 'id': 'order'});
    await tester.pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();
    // 「查看已有提现申请」位于钱包首页卡片下方，点击后进入提现区并恢复订单。
    await flow.tap(tester, find.text('查看已有提现申请'));

    final start = decorationOf(tester, '开始新的提现');
    expect(start.color, isNull);
    expect(start.border, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancel withdrawal request uses the destructive red fill',
      (tester) async {
    final api = await flow.client((request) async => flow.json(
        request.url.path.endsWith('/binding')
            ? boundFixture()
            : request.url.path.contains('/payout-quotes/')
                ? fixtures.quote
                : fixtures.payout));
    final store = ManualOperationStore(api);
    await store.initialize();
    await store.begin('payout', {'quote_id': 'quote', 'id': 'order'});
    await tester.pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();
    await flow.tap(tester, find.text('查看已有提现申请'));

    expect(find.text('取消提现申请'), findsOneWidget);
    final cancel = decorationOf(tester, '取消提现申请');
    // 色号取 UI 设计规范 --color-danger (#fa5151)。
    expect(cancel.color, WeChatColors.dangerFill);
    expect((cancel.border! as Border).top.color, WeChatColors.dangerFill);
    expect(labelOf(tester, '取消提现申请').style?.color, CupertinoColors.white);
    expect(tester.takeException(), isNull);
  });
}
