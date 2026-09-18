import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/caibi/caibi_page.dart';
import 'package:liuhetong_mobile/features/finance/wallet_entry_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../wallet/manual_wallet_flow_test.dart' as flow;

/// 点钻页进入态（2026-09-18）：余额/流水/本月汇总合并为一份缓存优先快照。
/// 之前 `FutureBuilder` 每次进入都替换 future，失败就用「暂不可用」覆盖上一份
/// 好数据（余额闪一下再恢复）。现在有缓存时先渲染缓存，刷新失败保留旧值。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WalletEntryStores.disposeAll();
  });

  testWidgets('有缓存：先渲染缓存余额与流水；刷新失败保留旧值且不显示暂不可用',
      (tester) async {
    final api = await flow.client((_) async => flow.json({}));
    final gateway = _ScriptedGateway(epoch: api.sessionEpoch)
      ..results.add(_snapshot(balance: '123.45'));
    final shared = WalletEntryStores.of(
        scope: '${await api.walletIntentScope()}#caibi', gateway: gateway);
    await shared.enter();
    expect(shared.state.phase, WalletLoadPhase.success);
    gateway.failure = StateError('offline');

    await tester.pumpWidget(CupertinoApp(home: CaibiPage(api: api)));
    await tester.pumpAndSettle();

    expect(find.textContaining('123.45'), findsOneWidget,
        reason: '缓存优先：进入就用缓存渲染，余额不闪');
    expect(find.text('暂不可用'), findsNothing);
    expect(find.byKey(const Key('caibi-recent-row-1')), findsOneWidget,
        reason: '流水也用缓存渲染');
    expect(find.text('流水加载失败'), findsNothing);
    expect(find.byKey(const Key('caibi-recent-retry')), findsNothing);
    expect(find.byKey(const Key('caibi-balance-retry')), findsNothing);
    expect(shared.state.fatalError, isFalse);
  });

  testWidgets('无缓存：首次加载失败显示错误与重试，重试成功后恢复数据', (tester) async {
    final api = await flow.client((_) async => flow.json({}));
    final gateway = _ScriptedGateway(epoch: api.sessionEpoch)
      ..failure = StateError('offline');
    final shared = WalletEntryStores.of(
        scope: '${await api.walletIntentScope()}#caibi', gateway: gateway);

    await tester.pumpWidget(CupertinoApp(home: CaibiPage(api: api)));
    await tester.pumpAndSettle();

    expect(shared.state.fatalError, isTrue);
    expect(find.textContaining('暂不可用'), findsOneWidget);
    expect(find.byKey(const Key('caibi-balance-error')), findsOneWidget);
    expect(find.byKey(const Key('caibi-recent-retry')), findsOneWidget,
        reason: '无缓存失败必须给出重试入口，不静默');

    // 重试：接口恢复 → 数据就位，错误消失。
    gateway.failure = null;
    gateway.results.add(_snapshot(balance: '66.00'));
    await tester.tap(find.byKey(const Key('caibi-balance-retry')));
    await tester.pumpAndSettle();
    expect(find.textContaining('66.00'), findsOneWidget);
    expect(find.textContaining('暂不可用'), findsNothing);
    expect(find.byKey(const Key('caibi-balance-error')), findsNothing);
  });

  testWidgets('流水单独失败：只标记流水块，余额继续展示', (tester) async {
    final api = await flow.client((_) async => flow.json({}));
    final gateway = _ScriptedGateway(epoch: api.sessionEpoch)
      ..results.add(_snapshot(balance: '9.99', recentFailed: true));
    WalletEntryStores.of(
        scope: '${await api.walletIntentScope()}#caibi', gateway: gateway);

    await tester.pumpWidget(CupertinoApp(home: CaibiPage(api: api)));
    await tester.pumpAndSettle();

    expect(find.textContaining('9.99'), findsOneWidget,
        reason: '流水失败不得隐藏余额');
    expect(find.text('流水加载失败'), findsOneWidget);
    expect(find.byKey(const Key('caibi-recent-retry')), findsOneWidget);
  });

  testWidgets('没有网关（api 为空）时显示空态且不崩溃', (tester) async {
    await tester.pumpWidget(const CupertinoApp(home: CaibiPage()));
    await tester.pumpAndSettle();
    expect(find.textContaining('--'), findsOneWidget);
    expect(find.text('暂无点钻流水'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Map<String, dynamic> _snapshot(
        {required String balance, bool recentFailed = false}) =>
    {
      'balance': balance,
      'recent': {
        'items': recentFailed
            ? const []
            : [
                {
                  'id': 'row-1',
                  'kind': 'redpacket',
                  'amount': '12.00',
                  'status': 'SETTLED',
                  'created_at': '2026-09-18T10:00:00Z',
                  'description': '红包',
                }
              ],
      },
      'recent_failed': recentFailed,
      'monthly': {
        'items': [
          {'amount': '12.00'},
        ],
      },
      'monthly_failed': false,
    };

final class _ScriptedGateway implements WalletEntryGateway {
  _ScriptedGateway({required this.epoch});

  final int epoch;
  final List<Map<String, dynamic>> results = [];
  Object? failure;

  @override
  int get sessionEpoch => epoch;

  @override
  Future<Map<String, dynamic>> load() async {
    final pending = failure;
    if (pending != null) throw pending;
    if (results.isEmpty) throw StateError('no scripted result');
    return results.removeAt(0);
  }
}
