import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';
import 'package:liuhetong_mobile/features/finance/wallet_entry_snapshot_store.dart';
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

  testWidgets('wallet entry API requests share the page operation ID',
      (tester) async {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true), onRecord: records.add);
    final pageTrace = recorder.start(PerformanceOperationType.walletLoad);
    final api = await flow.client(
      (request) async => flow
          .json(request.url.path.endsWith('/binding') ? fixtures.binding : {}),
      performanceRecorder: recorder,
    );

    await tester.pumpWidget(CupertinoApp(
        home: ManualWalletPage(client: api, performanceTrace: pageTrace)));
    await tester.pumpAndSettle();

    expect(
        records.any((record) =>
            record.operation == PerformanceOperationType.apiRequest &&
            record.endpointCategory == PerformanceEndpointCategory.finance &&
            record.operationId == pageTrace.operationId),
        isTrue);

    final refresh = find.byKey(const Key('manual-refresh'));
    await tester.ensureVisible(refresh);
    await tester.tap(refresh);
    await tester.pumpAndSettle();
    final refreshRecords = records
        .where((record) =>
            record.operation == PerformanceOperationType.walletLoad &&
            record.operationId != pageTrace.operationId)
        .toList();
    expect(refreshRecords, isNotEmpty);
    expect(
        records.any((record) =>
            record.operation == PerformanceOperationType.apiRequest &&
            record.endpointCategory == PerformanceEndpointCategory.finance &&
            record.operationId == refreshRecords.last.operationId),
        isTrue);
  });

  testWidgets('有缓存：进入立即渲染缓存；后台刷新失败不弹错、不清空', (tester) async {
    final records = <PerformanceRecord>[];
    final trace = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      onRecord: records.add,
    ).start(PerformanceOperationType.walletLoad);
    final api = await flow.client((request) async => flow
        .json(request.url.path.endsWith('/binding') ? fixtures.binding : {}));
    var now = DateTime(2026, 9, 25);
    final gateway = _ScriptedGateway(epoch: api.sessionEpoch)
      ..results.add(_snapshot('88.88'));
    final shared = WalletEntryStores.of(
        scope: await api.walletIntentScope(), gateway: gateway, now: () => now);
    await shared.enter(); // 首次成功：缓存落地
    expect(shared.state.phase, WalletLoadPhase.success);

    // 之后每次刷新都失败（弱网）：必须保留缓存。
    now = now.add(const Duration(seconds: 31));
    gateway.failure = StateError('offline');
    await tester.pumpWidget(CupertinoApp(
        home: ManualWalletPage(client: api, performanceTrace: trace)));
    await tester.pumpAndSettle();

    final pageRecord = records.singleWhere(
      (record) => record.operationId == trace.operationId,
    );
    final refreshRecord = records.singleWhere(
      (record) => record.operationId != trace.operationId,
    );
    expect(
        pageRecord.stagesUs.keys,
        containsAll([
          PerformanceStage.routeEnter,
          PerformanceStage.firstFrameRendered,
          PerformanceStage.cacheLoadDone,
          PerformanceStage.contentReady,
        ]));
    expect(
        refreshRecord.stagesUs.keys,
        containsAll([
          PerformanceStage.remoteRefreshStarted,
          PerformanceStage.remoteRefreshDone,
        ]));
    expect(pageRecord.stagesUs[PerformanceStage.firstFrameRendered],
        lessThanOrEqualTo(pageRecord.stagesUs[PerformanceStage.contentReady]!));
    expect(
        refreshRecord.stagesUs[PerformanceStage.remoteRefreshStarted],
        lessThanOrEqualTo(
            refreshRecord.stagesUs[PerformanceStage.remoteRefreshDone]!));

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
    final api = await flow.client((request) async => flow
        .json(request.url.path.endsWith('/binding') ? fixtures.binding : {}));
    final gateway = _ScriptedGateway(epoch: api.sessionEpoch)
      ..failure = StateError('offline');
    final shared = WalletEntryStores.of(
        scope: await api.walletIntentScope(), gateway: gateway);

    await tester.pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();

    expect(shared.state.fatalError, isTrue);
    expect(find.textContaining('功能状态暂不可用'), findsOneWidget);
    expect(find.textContaining('点钻余额加载失败'), findsWidgets);
    // 失败不静默：页面上必须有可见的重试入口（刷新按钮）。
    expect(find.byKey(const Key('manual-refresh')), findsOneWidget);
  });

  /// 用户报告（2026-09-19）：「无网/断网情况，无法加载绑定钱包，无法进入充值/提现页」。
  /// 上一版缓存只活在进程内存里，重启即丢；绑定状态更是只走网络（`bindingFresh`
  /// 只有在 `bindingStatus()` 成功后才为真）。这里验证本地快照把两件事一起解决：
  /// 断网也能看到已绑定地址与余额，充值入口仍然可用，并且不弹错。
  testWidgets('断网 + 本地快照：绑定信息与余额可见、充值入口可用、不弹错', (tester) async {
    final api = await flow.client((request) async {
      throw StateError('offline');
    });
    final scope = await api.walletIntentScope();
    final snapshots = InMemoryWalletEntrySnapshotStore();
    await snapshots.write(
        scope,
        WalletEntrySnapshot(
            data: _snapshot('88.88'), savedAt: DateTime(2026, 9, 19, 7)));
    WalletEntryStores.snapshots = snapshots;
    addTearDown(() => WalletEntryStores.snapshots = null);

    await tester.pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();

    final address = tester
        .widget<Text>(find.byKey(const Key('manual-wallet-bound-address')));
    expect(address.data, 'T***123', reason: '断网时必须仍能看到已绑定钱包地址');
    expect(find.text('已绑定'), findsOneWidget);
    expect(find.textContaining('88.88'), findsOneWidget);

    // 失败不覆盖、不弹错：余额与绑定都保留，且没有致命错误提示。
    expect(find.textContaining('功能状态暂不可用'), findsNothing);
    expect(find.textContaining('点钻余额加载失败'), findsNothing);
    expect(find.byType(CupertinoAlertDialog), findsNothing);

    // 入口仍可用：断网下点「充值」必须真的进入充值页（步骤指示器出现）。
    await tester.tap(find.text('充值'));
    await tester.pumpAndSettle();
    expect(find.text('填写金额'), findsWidgets, reason: '有本地快照时充值入口不得因为一次网络失败被禁用');
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
      'binding': const {
        'status': 'ACTIVE',
        'id': 'binding',
        'version': 1,
        'masked_address': 'T***123',
        'address': 'TXk9ztestsnapshotaddress000000000',
        'pending_id': null,
        'next_rebind_at': null,
        'binding_enabled': true,
        'unavailable_dependencies': <String>[],
        'rebind_interval_days': 30,
      },
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
