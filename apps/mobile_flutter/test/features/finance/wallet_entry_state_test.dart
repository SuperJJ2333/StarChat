import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_api_error.dart';
import 'package:liuhetong_mobile/features/finance/wallet_entry_snapshot_store.dart';
import 'package:liuhetong_mobile/features/finance/wallet_entry_store.dart';

/// 钱包进入态：缓存优先 + 后台刷新。
///
/// 这些用例覆盖用户报告的「每次进入钱包：按钮闪烁 → 错误提示短暂出现 →
/// 数据恢复」，全部注入假网关，不触网。
void main() {
  test(
      'warm re-entry within 30 seconds reuses success, explicit refresh bypasses it',
      () async {
    var now = DateTime(2026, 9, 23);
    final gateway = _FakeWalletGateway();
    final store = WalletEntryStore(gateway: gateway, now: () => now);
    addTearDown(store.dispose);
    await _primeCache(store, gateway, {'caibi_available': '10.00'});
    await store.enter(maxAge: const Duration(seconds: 30));
    expect(gateway.calls, 1);
    now = now.add(const Duration(seconds: 31));
    await store.enter(maxAge: const Duration(seconds: 30));
    expect(gateway.calls, 2);
    gateway.succeed({'caibi_available': '11.00'});
    await store.refresh();
    final forced = store.refresh();
    expect(gateway.calls, 3);
    gateway.succeed({'caibi_available': '12.00'});
    await forced;
  });

  test('in-flight result from an ended account is never cached', () async {
    final gateway = _FakeWalletGateway();
    final snapshots = _FakeSnapshotStore();
    final store = WalletEntryStore(
        gateway: gateway, scope: 'alice', snapshots: snapshots);
    addTearDown(store.dispose);
    final pending = store.refresh();
    gateway.sessionEpoch++;
    gateway.succeed({'caibi_available': '99.00'});
    await pending;
    expect(store.state.hasData, isFalse);
    expect(snapshots.writes, 0);
  });
  group('钱包进入态（缓存优先 + 后台刷新）', () {
    test('1. 首次进入（无缓存、接口成功）：只加载一次并最终 success，不出现空态闪烁', () async {
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

    test('2. 第二次进入（有缓存）：立即拿到 cached 数据，后台刷新到 success，期间数据从不为空', () async {
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

    test('9. 只读状态视图：值相等不视为变化，致命错误只属于无缓存的首次失败', () async {
      expect(
          const WalletEntryState(
                  phase: WalletLoadPhase.success, data: {'v': '1'}) ==
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

  /// 用户报告（2026-09-19）：「每次进入钱包子页面都会闪烁加载、短暂显示错误警告，
  /// 然后恢复正常；无网/断网时无法加载绑定钱包，也进不去充值/提现页。」
  ///
  /// 这些用例覆盖微信级加载模型的第 1 条（本地优先）与跨进程持久化：
  /// Store 只活在内存里时，进程重启后每个子页面（钱包/点钻/充值/提现）都必然重走
  /// 「空态 → 失败弹错 → 有网才恢复」，断网时则完全没有数据可展示、能力位拿不到，
  /// 于是入口被禁用。快照必须落本地并在**构造 Store 时**就生效。
  group('钱包进入态：本地快照持久化（跨进程 / 断网）', () {
    test('10. 新进程构造 Store 时先读本地快照：构造完即 cached，且有数据可渲染', () {
      final snapshots = _FakeSnapshotStore({
        's1': WalletEntrySnapshot(
          data: const {'caibi_available': '10.00'},
          savedAt: DateTime(2026, 9, 19, 7),
        ),
      });
      final gateway = _FakeWalletGateway();
      final store =
          WalletEntryStore(gateway: gateway, scope: 's1', snapshots: snapshots);
      addTearDown(store.dispose);

      expect(store.state.hasData, isTrue, reason: '首帧就要有数据，不能等网络');
      expect(store.state.data, {'caibi_available': '10.00'});
      expect(store.state.phase, WalletLoadPhase.cached);
      expect(store.state.updatedAt, DateTime(2026, 9, 19, 7));
      expect(gateway.calls, 0, reason: '构造 Store 本身不得发请求');
    });

    test('11. 断网进入：本地快照仍在、phase 不为 failed、无致命错误', () async {
      final snapshots = _FakeSnapshotStore({
        's1': WalletEntrySnapshot(
          data: const {
            'caibi_available': '10.00',
            'config': {'funding_enabled': true, 'manual_payout_enabled': true},
          },
          savedAt: DateTime(2026, 9, 19, 7),
        ),
      });
      final gateway = _FakeWalletGateway();
      final store =
          WalletEntryStore(gateway: gateway, scope: 's1', snapshots: snapshots);
      addTearDown(store.dispose);

      final fatalFlags = <bool>[];
      store.view.addListener(() => fatalFlags.add(store.state.fatalError));

      final entered = store.enter();
      gateway.fail(StateError('offline'));
      await entered;

      expect(store.state.phase, WalletLoadPhase.cached);
      expect(store.state.data!['caibi_available'], '10.00');
      expect(store.state.data!['config'],
          {'funding_enabled': true, 'manual_payout_enabled': true},
          reason: '能力位也要能从本地快照恢复，否则断网时充值/提现入口不可用');
      expect(store.state.fatalError, isFalse);
      expect(fatalFlags.any((fatal) => fatal), isFalse,
          reason: '有本地快照时任何一次通知都不得要求页面弹错');
      expect(store.state.hasData, isTrue, reason: '断网全程都不得清空数据');
    });

    test('12. 刷新成功写入本地快照；账号切换丢弃该作用域快照', () async {
      final snapshots = _FakeSnapshotStore();
      final gateway = _FakeWalletGateway();
      final store =
          WalletEntryStore(gateway: gateway, scope: 's1', snapshots: snapshots);
      addTearDown(store.dispose);

      final entered = store.enter();
      gateway.succeed({'caibi_available': '10.00'});
      await entered;
      expect(snapshots.writes, 1, reason: '成功后必须落盘，供下次启动使用');
      expect(snapshots.read('s1')!.data, {'caibi_available': '10.00'});

      // 账号切换：另一个账号的金融数据绝不能跨账号复用。
      gateway.sessionEpoch = 2;
      final refreshed = store.refresh();
      expect(snapshots.read('s1'), isNull, reason: 'epoch 变化时必须清掉该作用域的本地快照');
      gateway.succeed({'caibi_available': '0.00'});
      await refreshed;
      expect(store.state.data, {'caibi_available': '0.00'});
    });

    test('13. 注册表把共享快照存储接给页面：页面接线不变也能拿到本地快照', () async {
      addTearDown(WalletEntryStores.disposeAll);
      final snapshots = _FakeSnapshotStore({
        's1': WalletEntrySnapshot(
          data: const {'caibi_available': '10.00'},
          savedAt: DateTime(2026, 9, 19, 7),
        ),
      });
      addTearDown(() => WalletEntryStores.snapshots = null);
      WalletEntryStores.snapshots = snapshots;

      final store =
          WalletEntryStores.of(scope: 's1', gateway: _FakeWalletGateway());
      expect(store.state.hasData, isTrue, reason: '页面只调用 of()，共享快照存储必须由注册表补齐');
      expect(store.state.data, {'caibi_available': '10.00'});
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

  void succeed(Map<String, dynamic> data) =>
      _pending.removeAt(0).complete(data);
  void fail(Object error) => _pending.removeAt(0).completeError(error);
}

final class _FakeSnapshotStore implements WalletEntrySnapshotStore {
  _FakeSnapshotStore([Map<String, WalletEntrySnapshot>? seed])
      : _entries = {...?seed};

  final Map<String, WalletEntrySnapshot> _entries;
  int writes = 0;
  int clears = 0;

  @override
  WalletEntrySnapshot? read(String scope) => _entries[scope];

  @override
  Future<void> write(String scope, WalletEntrySnapshot snapshot) async {
    writes++;
    _entries[scope] = snapshot;
  }

  @override
  Future<void> clear(String scope) async {
    clears++;
    _entries.remove(scope);
  }

  @override
  Future<void> clearAll() async {
    clears++;
    _entries.clear();
  }
}
