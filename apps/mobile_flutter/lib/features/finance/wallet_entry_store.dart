import 'dart:async';

import 'package:flutter/foundation.dart';

import 'wallet_entry_snapshot_store.dart';

/// 钱包进入加载阶段。
///
/// 与既有 [FinanceCardState] 的 `loading`/`error` 布尔风格保持一致，但把
/// 「有缓存」和「无缓存」两种失败彻底分开，页面因此不再需要「先清空再等接口」：
///
/// - [initial]    从未成功加载过、也没有任何缓存（只有 Store 刚创建、尚未
///                `enter()` 时才是这个阶段）。
/// - [cached]     有数据、当前没有请求在飞。数据来自上一次成功结果，也可能是
///                刷新失败后的回退（此时 [WalletEntryState.lastError] 可查）。
/// - [refreshing] 有请求在飞。有缓存时是「后台刷新」，无缓存时是「首次加载」。
/// - [success]    最近一次刷新成功，[WalletEntryState.data] 是服务端最新值。
/// - [failed]     从未成功过且最近一次刷新失败、没有任何数据可展示；这是**唯一**
///                需要页面弹错/红色错误条的阶段。
enum WalletLoadPhase { initial, cached, refreshing, success, failed }

/// 钱包只读状态视图。页面**不得**直接修改，只能通过 [WalletEntryStore.enter] /
/// [WalletEntryStore.refresh] 触发加载，并用 [WalletEntryStore.view] 订阅。
@immutable
final class WalletEntryState {
  const WalletEntryState({
    this.phase = WalletLoadPhase.initial,
    this.data,
    this.lastError,
    this.updatedAt,
  });

  final WalletLoadPhase phase;

  /// 最近一次成功加载的权威快照；**刷新失败时不会被清空**。
  /// 只读快照，业务语义（金额、账本、权限）仍由业务 API 权威判定。
  final Map<String, dynamic>? data;

  /// 最近一次失败原因，仅用于诊断或弱提示（例如角标）。是否属于必须弹错的
  /// 致命错误由 [fatalError] 判定，而不是「非空即致命」。
  final Object? lastError;

  /// 最近一次成功刷新的本机时间，用于弱提示（例如「刚刚更新」）。
  final DateTime? updatedAt;

  /// 是否有可展示的数据（缓存或最新）。
  bool get hasData => data != null;

  /// 是否有请求在飞。
  bool get refreshing => phase == WalletLoadPhase.refreshing;

  /// 是否为「没有任何数据可展示的失败」：只有这种失败才允许页面弹错、
  /// 显示红色错误条或展示重试引导。有缓存的刷新失败一律为 `false`。
  bool get fatalError => phase == WalletLoadPhase.failed && lastError != null;

  @override
  bool operator ==(Object other) =>
      other is WalletEntryState &&
      other.phase == phase &&
      other.updatedAt == updatedAt &&
      identical(other.lastError, lastError) &&
      _sameData(other.data, data);

  @override
  int get hashCode {
    final snapshot = data;
    var dataHash = 0;
    if (snapshot != null) {
      for (final entry in snapshot.entries) {
        dataHash ^= Object.hash(entry.key, entry.value);
      }
    }
    return Object.hash(phase, lastError, updatedAt, dataHash);
  }

  @override
  String toString() =>
      'WalletEntryState(phase: $phase, hasData: $hasData, '
      'lastError: $lastError, updatedAt: $updatedAt)';
}

/// 拉取钱包权威快照的注入点。测试注入假实现，生产由 `BusinessApiClient` 实现。
abstract interface class WalletEntryGateway {
  /// 登录会话序号。变化表示账号已切换，缓存必须立即作废——金融数据绝不跨账号展示。
  int get sessionEpoch;

  /// 拉取一次钱包快照（能力配置 / 绑定状态 / 余额等由实现合并成一份快照）。
  /// 抛错表示本次刷新失败。
  Future<Map<String, dynamic>> load();
}

/// 钱包进入态 Store：**缓存优先 + 后台刷新**。
///
/// 生命周期（谁持有、谁 dispose）：
/// - 生产使用 [WalletEntryStores.of] 取得**进程内共享实例**，因此「第二次进入钱包」
///   拿到的仍是缓存，不会重建丢数据；
/// - 页面只**借用**：`store.view.addListener(...)` / `removeListener(...)`，
///   绝不在 `State.dispose()` 里 dispose Store；
/// - 持有者（AppHome 等会话级宿主）在退出登录、切换账号、钱包作用域变化时调用
///   [WalletEntryStores.disposeScope] / [WalletEntryStores.disposeAll] 释放；
/// - 测试可直接构造并 `dispose()`。
final class WalletEntryStore {
  WalletEntryStore({
    required this.gateway,
    this.scope = '',
    WalletEntrySnapshotStore? snapshots,
    DateTime Function()? now,
  })  : _now = now ?? DateTime.now,
        _snapshots = snapshots,
        _epoch = gateway.sessionEpoch {
    _hydrateFromSnapshot();
  }

  final WalletEntryGateway gateway;

  /// 钱包作用域（由页面提供，例如 `walletIntentScope()`），仅用于诊断与注册表分组。
  /// 同时是本地快照的键：作用域里含账号主体，因此快照天然按账号隔离。
  final String scope;

  final WalletEntrySnapshotStore? _snapshots;

  /// 本地快照 → 首帧数据。**必须同步**：页面在构造 Store 之后立刻 build，
  /// 异步读取会让首帧又回到「空态 → 有网才恢复」的老问题。
  void _hydrateFromSnapshot() {
    final snapshot = _snapshots?.read(scope);
    if (snapshot == null || snapshot.data.isEmpty) return;
    _view.value = WalletEntryState(
      phase: WalletLoadPhase.cached,
      data: Map<String, dynamic>.unmodifiable(snapshot.data),
      updatedAt: snapshot.savedAt,
    );
  }

  final DateTime Function() _now;
  final ValueNotifier<WalletEntryState> _view =
      ValueNotifier<WalletEntryState>(const WalletEntryState());
  int _epoch;
  Future<void>? _inFlight;
  bool _retired = false;
  bool _disposed = false;

  /// 只读状态视图：`ValueListenableBuilder(valueListenable: store.view, ...)`。
  ValueListenable<WalletEntryState> get view => _view;

  /// 当前状态（只读）。
  WalletEntryState get state => _view.value;

  bool get disposed => _disposed;

  /// 页面进入钱包时调用：**先展示缓存，再后台刷新**。
  ///
  /// - 已有缓存：立即返回（不阻塞首帧），刷新在后台进行；期间数据从不清空。
  /// - 没有缓存：等待首次加载结束（成功 → `success`，失败 → `failed`）。
  Future<void> enter() async {
    if (_disposed || _retired) return;
    if (state.hasData) {
      unawaited(refresh());
      return;
    }
    await refresh();
  }

  /// 发起一次加载（页面刷新按钮、下拉刷新、可见性变化、定时刷新共用）。
  ///
  /// 已有请求在飞时复用同一个 future，不重复打网络。
  Future<void> refresh() {
    if (_disposed || _retired) return Future<void>.value();
    _dropCacheOnEpochDrift();
    final running = _inFlight;
    if (running != null) return running;
    final future = _run();
    _inFlight = future;
    // 清理自己的 in-flight 标记（不吞掉调用方等待的那个 future）。
    future.whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
    return future;
  }

  Future<void> _run() async {
    final previous = state;
    final cached = previous.data;
    _emit(WalletEntryState(
      phase: WalletLoadPhase.refreshing,
      data: cached,
      updatedAt: previous.updatedAt,
    ));
    try {
      final loaded = await gateway.load();
      if (_disposed || _retired) return;
      final stamp = _now();
      _emit(WalletEntryState(
        phase: WalletLoadPhase.success,
        data: Map<String, dynamic>.unmodifiable(loaded),
        updatedAt: stamp,
      ));
      // 成功结果落本地：下次启动（或断网）直接有数据可展示。写盘失败不影响本次刷新，
      // 只影响下一次启动，因此单独吞掉，绝不升级为页面错误。
      final snapshots = _snapshots;
      if (snapshots != null) {
        try {
          await snapshots.write(
            scope,
            WalletEntrySnapshot(
              data: Map<String, dynamic>.unmodifiable(loaded),
              savedAt: stamp,
            ),
          );
        } catch (_) {
          // 本地快照写入失败不是刷新失败。
        }
      }
    } catch (error) {
      if (_disposed || _retired) return;
      _emit(cached == null
          // 首次加载失败（无缓存）：只有这一种失败需要页面弹错。
          ? WalletEntryState(phase: WalletLoadPhase.failed, lastError: error)
          // 刷新失败但有缓存：保留数据、不弹错、不显示红色错误条。
          : WalletEntryState(
              phase: WalletLoadPhase.cached,
              data: cached,
              lastError: error,
              updatedAt: previous.updatedAt,
            ));
    }
  }

  /// 账号切换保护：会话 epoch 变化时立即丢弃上一个账号的缓存**与本地快照**。
  void _dropCacheOnEpochDrift() {
    if (gateway.sessionEpoch == _epoch) return;
    _epoch = gateway.sessionEpoch;
    _emit(const WalletEntryState());
    final snapshots = _snapshots;
    if (snapshots != null) unawaited(snapshots.clear(scope));
  }

  void _emit(WalletEntryState next) {
    // ValueNotifier 用 `==` 判重：状态真正变化时才通知订阅者。
    _view.value = next;
  }

  /// 停用并清空缓存（账号切换时由 [WalletEntryStores] 调用）。之后
  /// [enter] / [refresh] 均为 no-op，但订阅者仍可安全 removeListener / dispose。
  void retire() {
    if (_disposed || _retired) return;
    _retired = true;
    _emit(const WalletEntryState());
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _inFlight = null;
    _view.dispose();
  }
}

/// 进程内共享的 [WalletEntryStore] 注册表。
///
/// 「缓存优先」的前提是 Store 实例跨页面进入复用：页面每次进入都 new 一个 Store，
/// 缓存必然丢失，只能重新走一遍空态 → 数据。持有者是会话级宿主（AppHome），
/// 页面只借用；宿主在退出登录 / 切换账号时释放。
final class WalletEntryStores {
  WalletEntryStores._();

  static final Map<String, WalletEntryStore> _stores = {};

  static WalletEntrySnapshotStore? _snapshots;

  /// 页面借用的本地快照存储：显式设置优先（测试），否则用进程级共享实例
  /// （由启动序列 `WalletEntrySnapshotStores.ensureLoaded()` 装载）。
  static WalletEntrySnapshotStore? get snapshots =>
      _snapshots ?? WalletEntrySnapshotStores.shared;

  static set snapshots(WalletEntrySnapshotStore? value) => _snapshots = value;

  /// 取得该钱包作用域当前的共享 Store；键包含会话 epoch，账号切换后自然重建。
  static WalletEntryStore of({
    required String scope,
    required WalletEntryGateway gateway,
    DateTime Function()? now,
  }) {
    final key = '$scope#${gateway.sessionEpoch}';
    final existing = _stores[key];
    if (existing != null && !existing.disposed) return existing;
    // 同一作用域的旧 epoch 实例：从注册表摘除并停用（清空缓存）。不 dispose——
    // 可能仍有页面持有引用，dispose 会让它们的 removeListener 断言失败。
    // 注意：这里**不删本地快照**——下一个账号的作用域键不同，读不到旧数据；
    // 而同一账号重新登录时正需要这份快照来立即展示。
    for (final stale in _stores.keys
        .where((candidate) => candidate != key && candidate.startsWith('$scope#'))
        .toList()) {
      _stores.remove(stale)?.retire();
    }
    final created = WalletEntryStore(
      gateway: gateway,
      scope: scope,
      snapshots: snapshots,
      now: now,
    );
    _stores[key] = created;
    return created;
  }

  /// 释放某个钱包作用域的全部共享 Store（退出登录 / 钱包作用域变化）。
  static void disposeScope(String scope) {
    for (final key in _stores.keys
        .where((candidate) =>
            candidate == scope || candidate.startsWith('$scope#'))
        .toList()) {
      _stores.remove(key)?.dispose();
    }
  }

  /// 释放全部共享 Store（退出登录）。
  static void disposeAll() {
    for (final store in _stores.values) {
      store.dispose();
    }
    _stores.clear();
    final store = snapshots;
    if (store != null) unawaited(store.clearAll());
  }

  @visibleForTesting
  static int get instanceCount => _stores.length;
}

bool _sameData(Map<String, dynamic>? a, Map<String, dynamic>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  return mapEquals(a, b);
}
