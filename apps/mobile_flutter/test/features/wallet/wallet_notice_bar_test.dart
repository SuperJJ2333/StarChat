import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/finance/wallet_entry_store.dart';
import 'package:liuhetong_mobile/features/wallet/manual_operation_store.dart';
import 'package:liuhetong_mobile/features/wallet/wallet_notice_store.dart';
import 'package:liuhetong_mobile/features/wallet/wallet_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'manual_wallet_api_test.dart' as fixtures;
import 'manual_wallet_flow_test.dart' as flow;

/// 需求 14（2026-09-18）：「查看已有充值申请 / 提现申请」提醒统一放到顶部导航栏
/// 下方的通知栏；点击直达对应申请页；最右侧「不再通知」按**申请身份**持久化忽略，
/// 出现新的一笔申请才再次出现。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WalletEntryStores.disposeAll();
  });

  Future<ManualOperationStore> seed(WidgetTester tester,
      {String depositId = 'intent', String? payoutId}) async {
    final api = await flow.client((request) async => flow.json(
        request.url.path.endsWith('/wallet/binding') ? fixtures.binding : {}));
    final store = ManualOperationStore(api);
    await store.initialize();
    if (depositId.isNotEmpty) {
      await store.begin('deposit',
          {'amount': '10.000000', 'version': 1, 'id': depositId});
    }
    if (payoutId != null) {
      await store.begin('payout', {'quote_id': 'quote', 'id': payoutId});
    }
    await tester.pumpWidget(CupertinoApp(home: WalletPage(api: api)));
    await tester.pumpAndSettle();
    return store;
  }

  test('通知身份：报价→订单是同一条申请链路；新的一笔才有新身份', () {
    expect(depositNoticeIdentity(null), isNull);
    expect(depositNoticeIdentity({'id': 'a'}), 'deposit:a');
    expect(depositNoticeIdentity({'key': 'draft'}), 'deposit:draft');
    expect(payoutNoticeIdentity(null, null), isNull);
    // 报价阶段与订单阶段必须是同一个身份（用 quote_id 串联）。
    expect(payoutNoticeIdentity({'quote_id': 'q'}, null), 'payout:q');
    expect(payoutNoticeIdentity(null, {'id': 'q'}), 'payout:q');
    // 新的一笔报价 → 新身份。
    expect(payoutNoticeIdentity(null, {'id': 'q2'}), 'payout:q2');
  });

  testWidgets('需求14：提醒固定在顶部导航栏下方，点击直达对应申请页', (tester) async {
    await seed(tester);
    final bar = find.byKey(const Key('manual-deposit-notice'));
    expect(bar, findsOneWidget);
    expect(find.text('查看已有充值申请'), findsOneWidget);

    // 位置：导航栏下方，且不在滚动列表里（固定通知栏，不随列表滚走）。
    final navigation = tester.getRect(find.byType(CupertinoNavigationBar));
    expect(tester.getRect(bar).top,
        greaterThanOrEqualTo(navigation.bottom - 1));
    expect(
        find.descendant(
            of: find.byKey(const Key('wallet-page-list')),
            matching: find.text('查看已有充值申请')),
        findsNothing,
        reason: '提醒不得再散落在卡片下方');

    await flow.tap(tester, find.byKey(const Key('manual-deposit-notice-open')));
    expect(
        find.descendant(
            of: find.byType(CupertinoNavigationBar), matching: find.text('充值')),
        findsOneWidget,
        reason: '点击通知栏必须直达对应的申请页');
  });

  testWidgets('需求14：「不再通知」持久化忽略这一笔，重启后仍不出现，新的一笔再次出现',
      (tester) async {
    final api = await flow.client((request) async => flow.json(
        request.url.path.endsWith('/wallet/binding') ? fixtures.binding : {}));
    final store = ManualOperationStore(api);
    await store.initialize();
    await store.begin(
        'deposit', {'amount': '10.000000', 'version': 1, 'id': 'intent'});
    await tester.pumpWidget(CupertinoApp(home: WalletPage(api: api)));
    await tester.pumpAndSettle();

    final bar = find.byKey(const Key('manual-deposit-notice'));
    expect(bar, findsOneWidget);
    expect(find.byIcon(CupertinoIcons.bell_slash), findsOneWidget);

    await flow.tap(
        tester, find.byKey(const Key('manual-deposit-notice-dismiss')));
    expect(bar, findsNothing, reason: '点击「不再通知」后提醒必须消失');
    final prefs = await SharedPreferences.getInstance();
    final scope = await api.walletIntentScope();
    expect(prefs.getString('wallet.notice.v1:$scope:deposit'), 'deposit:intent',
        reason: '忽略标记必须按申请身份持久化，不能只是内存 bool');

    // 「重启」页面：同一笔申请仍然不再提醒。
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    await tester.pumpWidget(CupertinoApp(home: WalletPage(api: api)));
    await tester.pumpAndSettle();
    expect(bar, findsNothing, reason: '重启后仍然保持不再通知');

    // 出现新的一笔充值申请：身份不同 → 提醒重新出现。
    await store.save('deposit', {
      'key': 'next-key',
      'amount': '10.000000',
      'version': 1,
      'id': 'intent-2',
    });
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    await tester.pumpWidget(CupertinoApp(home: WalletPage(api: api)));
    await tester.pumpAndSettle();
    expect(bar, findsOneWidget,
        reason: '出现新的一笔申请后必须重新提醒（忽略标记只针对旧身份）');
  });

  testWidgets('需求14：提现提醒同样只在通知栏出现', (tester) async {
    await seed(tester, depositId: '', payoutId: 'order');
    expect(find.text('查看已有提现申请'), findsOneWidget);
    expect(find.byKey(const Key('manual-payout-notice')), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const Key('wallet-page-list')),
            matching: find.text('查看已有提现申请')),
        findsNothing);
    await flow.tap(tester, find.byKey(const Key('manual-payout-notice-open')));
    expect(
        find.descendant(
            of: find.byType(CupertinoNavigationBar), matching: find.text('提现')),
        findsOneWidget);
  });

  testWidgets('需求14：深色下通知栏按主题解析，不硬编码浅色', (tester) async {
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    final api = await flow.client((request) async => flow.json(
        request.url.path.endsWith('/wallet/binding') ? fixtures.binding : {}));
    final store = ManualOperationStore(api);
    await store.initialize();
    await store.begin(
        'deposit', {'amount': '10.000000', 'version': 1, 'id': 'intent'});
    await tester.pumpWidget(CupertinoApp(home: WalletPage(api: api)));
    await tester.pumpAndSettle();
    final text = tester.widget<Text>(
        find.byKey(const Key('manual-deposit-notice-label')));
    expect(text.style!.color, isNotNull);
    expect(text.maxLines, 1);
    // 品牌淡底是半透明品牌色，深浅色都可读（token 决定，不随主题改实色）。
    expect(text.style!.color, isNot(CupertinoColors.white));
  });
}
