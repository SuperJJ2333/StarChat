import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_api_error.dart';
import 'package:liuhetong_mobile/features/finance/wallet_entry_store.dart';

/// 钱包进入态：缓存优先 + 后台刷新。
///
/// 这些用例覆盖用户报告的「每次进入钱包：按钮闪烁 → 错误提示短暂出现 →
/// 数据恢复」，全部注入假网关，不触网。
void main() {
  group('钱包进入态（缓存优先 + 后台刷新）', () {
    test('1. 首次进入（无缓存、接口成功）：只加载一次并最终 success，不出现空态闪烁',
        () async {
      final gateway = _FakeWalletGateway();
      final store = WalletEntryStore(gateway: gateway);
      addTearDown(store.dispose);

      final phases = <WalletLoadPhase>[];
      final emptyNotifications = <bool>[];
      store.view.addListener(() {
        phases.add(store.state.phase);
        emptyNotifications.add(!store.state.hasData);
      });

      // 只有「从未进入过」的 Store 才是 initial 空态。
      expect(store.state.phase, WalletLoadPhase.initial);
      expect(store.state.hasData, isFalse);

      final entered = store.enter();
      expect(store.state.phase, WalletLoadPhase.refreshing);
      expect(store.state.refreshing, isTrue);
      expect(store.state.hasData, isFalse);
      expect(gateway.calls, 1, reason: '首次进入只允许一次有效加载');

      gateway.succeed({'caibi_available': '10.00'});
      await entered;

      expect(store.state.phase, WalletLoadPhase.success);
      expect(store.state.hasData, isTrue);
      expect(store.state.data, {'caibi_available': '10.00'});
      expect(store.state.lastError, isNull);
      expect(store.state.fatalError, isFalse);
      expect(gateway.calls, 1, reason: '首次进入结束后不得再补一次请求');

      // 阶段序列里没有 initial、没有 failed：不存在「空态 → 数据 → 空态」的闪烁。
      expect(phases, [WalletLoadPhase.refreshing, WalletLoadPhase.success]);
      expect(phases.contains(WalletLoadPhase.initial), isFalse);
      expect(emptyNotifications.last, isFalse);
    });

    test('2. 第二次进入（有缓存）：立即拿到 cached 数据，后台刷新到 success，期间数据从不为空',
        () async {
      final gateway = _FakeWalletGateway();
      final store = WalletEntryStore(gateway: gateway);
      addTearDown(store.dispose);
      await _primeCache(store, gateway, {'caibi_available': '10.00'});
      expect(store.state.phase, WalletLoadPhase.success);

      final phases = <WalletLoadPhase>[];
      final dataSeen = <Object?>[];
      store.view.addListener(() {
        phases.add(store.state.phase);
        dataSeen.add(store.state.data);
      });

      // 第二次进入（页面 State 重建，但 Store 实例复用，见用例 6）。
      final entered = store.enter();
      expect(store.state.hasData, isTrue, reason: '进入瞬间必须已有缓存数据');
      expect(store.state.data, {'caibi_available': '10.00'});
      expect(store.state.phase, isNot(WalletLoadPhase.initial));
      expect(store.state.phase, WalletLoadPhase.refreshing,
          reason: '有缓存时进入即进入后台刷新态，绝不回到 initial 空态');
      expect(gateway.calls, 2);
      await entered; // 有缓存时 enter() 立即返回，不阻塞首帧

      gateway.succeed({'caibi_available': '25.50'});
      await store.refresh(); // 后台刷新结果落地

      expect(store.state.phase, WalletLoadPhase.success);
      expect(store.state.data, {'caibi_available': '25.50'});
      expect(phases, [WalletLoadPhase.refreshing, WalletLoadPhase.success]);
      expect(dataSeen.every((data) => data != null), isTrue,
          reason: '刷新全程数据不得被清空');
    });

    test('3. 弱网进入（刷新超时但有缓存）：数据仍在、phase 不为 failed、无致命错误', () async {
      final gateway = _FakeWalletGateway();
      final store = WalletEntryStore(gateway: gateway);
      addTearDown(store.dispose);
      await _primeCache(store, gateway, {'caibi_available': '10.00'});

      final refreshed = store.refresh();
      expect(store.state.phase, WalletLoadPhase.refreshing);
      expect(store.state.hasData, isTrue);
      gateway.fail(TimeoutException('弱网超时'));
      await refreshed;

      expect(store.state.phase, WalletLoadPhase.cached);
      expect(store.state.phase, isNot(WalletLoadPhase.failed));
      expect(store.state.hasData, isTrue);
      expect(store.state.data, {'caibi_available': '10.00'});
      expect(store.state.lastError, isA<TimeoutException>());
      expect(store.state.fatalError, isFalse, reason: '有缓存时不得弹错');
    });

    test('4. 接口失败但有缓存：同上，且全程不产生需要 UI 弹错的错误信号', () async {
      final gateway = _FakeWalletGateway();
      final store = WalletEntryStore(gateway: gateway);
      addTearDown(store.dispose);
      await _primeCache(store, gateway, {'caibi_available': '10.00'});

      final fatalFlags = <bool>[];
      store.view.addListener(() => fatalFlags.add(store.state.fatalError));

      final refreshed = store.refresh();
      gateway.fail(const BusinessApiException(
          statusCode: 500, code: 'INTERNAL', message: '服务暂不可用'));
      await refreshed;

      expect(store.state.phase, WalletLoadPhase.cached);
      expect(store.state.hasData, isTrue);
      expect(store.state.data, {'caibi_available': '10.00'});
      expect(store.state.lastError, isA<BusinessApiException>());
      expect(store.state.fatalError, isFalse);
      expect(fatalFlags.any((fatal) => fatal), isFalse,
          reason: '有缓存时任何一次通知都不得要求页面弹错');
    });

    test('5. 接口恢复：下一次刷新成功后 phase = success 且数据为新值', () async {
      final gateway = _FakeWalletGateway();
      final store = WalletEntryStore(gateway: gateway);
      addTearDown(store.dispose);
      await _primeCache(store, gateway, {'caibi_available': '10.00'});

      final broken = store.refresh();
      gateway.fail(StateError('offline'));
      await broken;
      expect(store.state.phase, WalletLoadPhase.cached);
      expect(store.state.lastError, isNotNull);

      final recovered = store.refresh();
      gateway.succeed({'caibi_available': '88.88'});
      await recovered;

      expect(store.state.phase, WalletLoadPhase.success);
      expect(store.state.data, {'caibi_available': '88.88'});
      expect(store.state.lastError, isNull, reason: '恢复后不得残留旧错误');
      expect(store.state.fatalError, isFalse);
    });

    test('6. Store 复用：同一钱包作用域跨两次进入是同一实例，缓存不丢', () async {
      addTearDown(WalletEntryStores.disposeAll);
      final gateway = _FakeWalletGateway();

      final first = WalletEntryStores.of(scope: 's1', gateway: gateway);
      final entered = first.enter();
      gateway.succeed({'caibi_available': '10.00'});
      await entered;

      // 第二次进入钱包：页面 State 会重建，但注册表必须交回同一实例。
      final second = WalletEntryStores.of(scope: 's1', gateway: gateway);
      expect(identical(first, second), isTrue);
      expect(second.state.hasData, isTrue, reason: '复用实例才不会丢缓存');
      expect(second.state.data, {'caibi_available': '10.00'});
      expect(WalletEntryStores.instanceCount, 1);

      // 另一个钱包作用域（另一个账号）不共享缓存。
      final other = WalletEntryStores.of(scope: 's2', gateway: gateway);
      expect(identical(other, first), isFalse);
      expect(other.state.hasData, isFalse);

      // 会话切换（epoch 变化）：旧实例停用并清空缓存，新实例从零加载。
      gateway.sessionEpoch = 2;
      final fresh = WalletEntryStores.of(scope: 's1', gateway: gateway);
      expect(identical(fresh, first), isFalse);
      expect(fresh.state.hasData, isFalse);
      expect(first.state.hasData, isFalse, reason: '旧会话的金融数据必须清空');
      expect(first.state.phase, WalletLoadPhase.initial);
    });

    test('7. 账号切换：被持有的旧 Store 在下次刷新前丢弃缓存，绝不跨账号展示', () async {
      final gateway = _FakeWalletGateway();
      final store = WalletEntryStore(gateway: gateway);
      addTearDown(store.dispose);
      await _primeCache(store, gateway, {'caibi_available': '10.00'});

      gateway.sessionEpoch = 2;
      final refreshed = store.refresh();
      expect(store.state.hasData, isFalse, reason: '同步丢弃上一个账号的余额');
      expect(store.state.phase, WalletLoadPhase.refreshing);
      gateway.succeed({'caibi_available': '0.00'});
      await refreshed;
      expect(store.state.data, {'caibi_available': '0.00'});
    });

    test('8. 并发进入/刷新合并为一次请求，状态未变化时不重复通知', () async {
      final gateway = _FakeWalletGateway();
      final store = WalletEntryStore(gateway: gateway);
      addTearDown(store.dispose);

      var notices = 0;
      store.view.addListener(() => notices++);

      final firstEnter = store.enter();
      final secondEnter = store.enter();
      expect(gateway.calls, 1);
      expect(notices, 1, reason: '重复进入不得重复通知');

      gateway.succeed({'caibi_available': '10.00'});
      await firstEnter;
      await secondEnter;
      expect(notices, 2);

      // 已有缓存时再次进入：只多一次 refreshing 通知，数据不丢。
      final thirdEnter = store.enter();
      expect(notices, 3);
      await thirdEnter;
      expect(store.state.phase, WalletLoadPhase.refreshing);
      expect(store.state.data, {'caibi_available': '10.00'});
      expect(gateway.calls, 2);

      gateway.succeed({'caibi_available': '10.00'});
      await store.refresh();
      expect(notices, 4, reason: '同值成功刷新只通知一次成功态');
      expect(store.state.phase, WalletLoadPhase.success);
    });

    test('9. 只读状态视图：值相等不视为变化，致命错误只属于无缓存的首次失败',
        () async {
      expect(
          const WalletEntryState(
                  phase: WalletLoadPhase.success, data: {'v': '1'})
              ==
              WalletEntryState(
                  phase: WalletLoadPhase.success,
                  data: {'v': '1'},
                  updatedAt: DateTime(2026)),
          isFalse,
          reason: 'updatedAt 不同即不同状态');
      expect(
          WalletEntryState(
                  phase: WalletLoadPhase.success,
                  data: {'v': '1'},
                  updatedAt: DateTime(2026)) ==
              WalletEntryState(
                  phase: WalletLoadPhase.success,
                  data: {'v': '1'},
                  updatedAt: DateTime(2026)),
          isTrue);

      final noCacheFailure = WalletEntryState(
          phase: WalletLoadPhase.failed, lastError: StateError('x'));
      expect(noCacheFailure.hasData, isFalse);
      expect(noCacheFailure.fatalError, isTrue);

      final cachedFailure = WalletEntryState(
          phase: WalletLoadPhase.cached,
          data: const {'v': '1'},
          lastError: StateError('x'));
      expect(cachedFailure.hasData, isTrue);
      expect(cachedFailure.fatalError, isFalse);
      expect(cachedFailure.refreshing, isFalse);
    });
  });
}

Future<void> _primeCache(WalletEntryStore store, _FakeWalletGateway gateway,
    Map<String, dynamic> data) async {
  final entered = store.enter();
  gateway.succeed(data);
  await entered;
  expect(store.state.hasData, isTrue);
}

final class _FakeWalletGateway implements WalletEntryGateway {
  final List<Completer<Map<String, dynamic>>> _pending = [];
  int calls = 0;
  @override
  int sessionEpoch = 1;

  @override
  Future<Map<String, dynamic>> load() {
    calls++;
    final completer = Completer<Map<String, dynamic>>();
    _pending.add(completer);
    return completer.future;
  }

  void succeed(Map<String, dynamic> data) => _pending.removeAt(0).complete(data);
  void fail(Object error) => _pending.removeAt(0).completeError(error);
}
