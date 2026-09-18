import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/finance/wallet_entry_store.dart';
import 'package:liuhetong_mobile/features/wallet/manual_wallet_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'manual_wallet_api_test.dart' as fixtures;
import 'manual_wallet_flow_test.dart' as flow;

/// 进入钱包的缓存优先契约（2026-09-18 用户报告「进入钱包：按钮闪烁 → 错误提示
/// 短暂出现 → 数据恢复」）：
/// - 有缓存时先渲染缓存，后台刷新失败**不弹错**、不清空（fatalError=false）；
/// - 无缓存首次失败才显示错误（fatalError=true）。
///
/// 网关通过注册表注入：`WalletEntryStores` 的键是 `钱包作用域#会话 epoch`，用与
/// 页面相同的 scope/epoch 预注册一个「脚本化网关」，页面 `of()` 就会复用它。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WalletEntryStores.disposeAll();
  });

  testWidgets('有缓存：进入立即渲染缓存；后台刷新失败不弹错、不清空', (tester) async {
    final api = await flow.client(
        (request) async => flow.json(request.url.path.endsWith('/binding')
            ? fixtures.binding
            : {}));
    final gateway = _ScriptedGateway(epoch: api.sessionEpoch)
      ..results.add(_snapshot('88.88'));
    final shared = WalletEntryStores.of(
        scope: await api.walletIntentScope(), gateway: gateway);
    await shared.enter(); // 首次成功：缓存落地
    expect(shared.state.phase, WalletLoadPhase.success);

    // 之后每次刷新都失败（弱网）：必须保留缓存。
    gateway.failure = StateError('offline');
    await tester.pumpWidget(
        CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();

    // 缓存数据渲染出来了（余额不是 '—'）。
    expect(find.textContaining('88.88'), findsOneWidget);
    // 有缓存 → 不是致命错误：不出现「功能状态暂不可用」，也没有错误弹窗/红条。
    expect(find.textContaining('功能状态暂不可用'), findsNothing);
    expect(find.textContaining('点钻余额加载失败'), findsNothing);
    expect(find.byType(CupertinoAlertDialog), findsNothing);
    expect(shared.state.fatalError, isFalse);
    expect(shared.state.hasData, isTrue);
  });

  testWidgets('无缓存：首次加载失败必须显示错误（可见、不静默）', (tester) async {
    final api = await flow.client(
        (request) async => flow.json(request.url.path.endsWith('/binding')
            ? fixtures.binding
            : {}));
    final gateway = _ScriptedGateway(epoch: api.sessionEpoch)
      ..failure = StateError('offline');
    final shared = WalletEntryStores.of(
        scope: await api.walletIntentScope(), gateway: gateway);

    await tester.pumpWidget(
        CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();

    expect(shared.state.fatalError, isTrue);
    expect(find.textContaining('功能状态暂不可用'), findsOneWidget);
    expect(find.textContaining('点钻余额加载失败'), findsWidgets);
    // 失败不静默：页面上必须有可见的重试入口（刷新按钮）。
    expect(find.byKey(const Key('manual-refresh')), findsOneWidget);
  });
}

Map<String, dynamic> _snapshot(String balance) => {
      'config': const {
        'funding_enabled': true,
        'manual_payout_enabled': true,
        'manual_payout_execution_enabled': true,
        'conversion_enabled': true,
        'caibi_payout_enabled': true,
      },
      'caibi_available': balance,
    };

final class _ScriptedGateway implements WalletEntryGateway {
  _ScriptedGateway({required this.epoch});

  final int epoch;
  final List<Map<String, dynamic>> results = [];
  Object? failure;
  int calls = 0;

  @override
  int get sessionEpoch => epoch;

  @override
  Future<Map<String, dynamic>> load() async {
    calls++;
    final pending = failure;
    if (pending != null) throw pending;
    if (results.isEmpty) throw StateError('no scripted result');
    return results.removeAt(0);
  }
}
