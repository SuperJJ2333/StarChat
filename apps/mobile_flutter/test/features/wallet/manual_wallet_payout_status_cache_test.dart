import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:liuhetong_mobile/features/finance/wallet_entry_store.dart';
import 'package:liuhetong_mobile/features/wallet/manual_payout_status_store.dart';
import 'package:liuhetong_mobile/features/wallet/manual_wallet_api.dart';
import 'package:liuhetong_mobile/features/wallet/manual_wallet_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'manual_wallet_api_test.dart' as fixtures;
import 'manual_wallet_flow_test.dart' as flow;

/// 提现申请状态的本地优先契约（2026-09-19 Mi 6 真机 A/B 发现的缺口）：
/// 断网冷启动时提现页只剩余额与步骤条，状态卡（订单 / 提现 USDT /
/// 「管理员人工付款处理中」）整块消失，因为 `payout` 只来自 `api.payout(id)`。
///
/// 这里锁死新的契约：
/// - 有本地快照 → 网络失败也展示状态卡（L1/L2/L4）；
/// - 无本地快照 → 保持原来的"失败可见"行为，不伪造状态；
/// - 快照按账号作用域隔离，换账号不得展示上一个账号的提现记录。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WalletEntryStores.disposeAll();
  });

  /// 断网：状态接口直接 HTTP 500（客户端抛业务异常）。
  Future<http.Response> offlinePayout(http.Request request) async {
    if (request.url.path.endsWith('/binding')) {
      return flow.json(fixtures.binding);
    }
    if (request.url.path.contains('/wallet/manual/payouts/')) {
      return http.Response('{"code":"UPSTREAM_UNAVAILABLE"}', 500,
          headers: {'content-type': 'application/json'});
    }
    return flow.json(const {});
  }

  testWidgets('断网冷启动：有本地状态快照就照常展示提现状态卡', (tester) async {
    final api = await flow.client(offlinePayout);
    final scope = await api.walletIntentScope();
    SharedPreferences.setMockInitialValues({
      'wallet.manual.v1:$scope:payout':
          jsonEncode({'key': 'idem', 'id': 'order', 'quote_id': 'quote'}),
      'wallet.payout.status.v1:$scope:order': jsonEncode(fixtures.payout),
    });

    await tester.pumpWidget(CupertinoApp(
      home: ManualWalletPage(
          client: api, section: ManualWalletSection.payout),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('管理员人工付款处理中'), findsOneWidget,
        reason: '断网也要能看到上次成功的申请状态');
    expect(find.textContaining('order'), findsWidgets, reason: '订单号可见');
    expect(find.textContaining('10.000000'), findsWidgets,
        reason: '提现金额可见');
  });

  testWidgets('无本地快照且断网：不伪造状态卡（保持失败可见）', (tester) async {
    final api = await flow.client(offlinePayout);
    final scope = await api.walletIntentScope();
    SharedPreferences.setMockInitialValues({
      'wallet.manual.v1:$scope:payout':
          jsonEncode({'key': 'idem', 'id': 'order', 'quote_id': 'quote'}),
    });

    await tester.pumpWidget(CupertinoApp(
      home: ManualWalletPage(
          client: api, section: ManualWalletSection.payout),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('管理员人工付款处理中'), findsNothing);
  });

  testWidgets('快照属于别的账号：不得展示上一个账号的提现记录', (tester) async {
    final api = await flow.client(offlinePayout);
    final scope = await api.walletIntentScope();
    SharedPreferences.setMockInitialValues({
      'wallet.manual.v1:$scope:payout':
          jsonEncode({'key': 'idem', 'id': 'order', 'quote_id': 'quote'}),
      'wallet.payout.status.v1:https://other.example:bob:order':
          jsonEncode(fixtures.payout),
    });

    await tester.pumpWidget(CupertinoApp(
      home: ManualWalletPage(
          client: api, section: ManualWalletSection.payout),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('管理员人工付款处理中'), findsNothing,
        reason: '跨账号快照必须失效');
  });

  group('ManualPayoutStatusStore', () {
    test('成功取回后写回快照，读回字段一致', () async {
      final api = await flow.client(offlinePayout);
      final store = ManualPayoutStatusStore(api);
      await store.initialize();
      expect(await store.read('order'), isNull);

      await store.save(ManualPayout.fromJson(fixtures.payout));
      final restored = await store.read('order');
      expect(restored, isNotNull);
      expect(restored!.id, 'order');
      expect(restored.amount, '10.000000');
      expect(restored.quoteId, 'quote');
      expect(restored.status.name.toUpperCase(), 'REQUESTED');

      await store.clear('order');
      expect(await store.read('order'), isNull);
    });

    test('未登记字段/损坏内容/id 不符一律按无本地数据处理', () async {
      final api = await flow.client(offlinePayout);
      final scope = await api.walletIntentScope();
      final store = ManualPayoutStatusStore(api);
      await store.initialize();

      // 未登记字段（例如被误写入的敏感字段）→ 拒绝读取。
      SharedPreferences.setMockInitialValues({
        'wallet.payout.status.v1:$scope:order':
            jsonEncode({...fixtures.payout, 'secret': 'x'}),
      });
      final withSecret = ManualPayoutStatusStore(api);
      await withSecret.initialize();
      expect(await withSecret.read('order'), isNull);

      // 损坏 JSON → null。
      SharedPreferences.setMockInitialValues(
          {'wallet.payout.status.v1:$scope:order': '{not-json'});
      final corrupt = ManualPayoutStatusStore(api);
      await corrupt.initialize();
      expect(await corrupt.read('order'), isNull);

      // 记录里的 id 与请求的 id 不一致 → null（不把别的申请当成这一笔）。
      SharedPreferences.setMockInitialValues({
        'wallet.payout.status.v1:$scope:order': jsonEncode(fixtures.payout),
      });
      expect(await store.read('other-order'), isNull);
    });

    test('只落非密展示字段（白名单显式登记）', () async {
      final api = await flow.client(offlinePayout);
      final store = ManualPayoutStatusStore(api);
      await store.initialize();
      await store.save(ManualPayout.fromJson(fixtures.payout));

      final prefs = await SharedPreferences.getInstance();
      final scope = await api.walletIntentScope();
      final raw = prefs.getString('wallet.payout.status.v1:$scope:order');
      final record = jsonDecode(raw!) as Map<String, dynamic>;
      expect(record.keys.toSet().difference(
          ManualPayoutStatusStore.allowedFields), isEmpty,
          reason: '落盘字段必须全部在白名单内');
      expect(record.containsKey('secret'), isFalse);
      expect(record.containsKey('key'), isFalse, reason: '幂等键不进状态快照');
    });
  });
}
