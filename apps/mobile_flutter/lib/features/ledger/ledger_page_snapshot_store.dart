import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 账单首页（无筛选的「全部账单」列表）的本地快照。
///
/// 微信级加载模型要求「本地优先 → 立即展示 → 后台同步 → 失败不覆盖」。
/// `LedgerController` 原先每次进入都是空列表 + 一次网络请求，刷新前还会先
/// `_items.clear()`：断网就只剩「账单加载失败，请重试」，有网也要先看一次空白。
/// 这里把**最后一次成功的首页**落本地，进入时同步水合，首帧即有内容。
///
/// 只缓存无筛选的首页（默认视图），筛选/搜索/分页结果不落盘：
/// - 体积可控（`limit` 条），也不会把某个筛选条件的旧结果当成当前结果；
/// - 快照里带账号作用域，读取方必须校验，账号切换后立即丢弃，账单绝不跨账号展示。
@immutable
final class LedgerPageSnapshot {
  const LedgerPageSnapshot({
    required this.scope,
    required this.items,
    required this.nextCursor,
    required this.savedAt,
  });

  /// 该快照属于哪个账号作用域（`<origin>:<subject>`）。
  final String scope;
  final List<Map<String, dynamic>> items;
  final String? nextCursor;
  final DateTime savedAt;
}

abstract interface class LedgerPageSnapshotStore {
  /// 同步读取：页面首帧就要用，不能等异步 IO。
  LedgerPageSnapshot? read();

  Future<void> write(LedgerPageSnapshot snapshot);

  Future<void> clear();
}

final class InMemoryLedgerPageSnapshotStore
    implements LedgerPageSnapshotStore {
  InMemoryLedgerPageSnapshotStore([this._snapshot]);

  LedgerPageSnapshot? _snapshot;

  @override
  LedgerPageSnapshot? read() => _snapshot;

  @override
  Future<void> write(LedgerPageSnapshot snapshot) async {
    _snapshot = snapshot;
  }

  @override
  Future<void> clear() async {
    _snapshot = null;
  }
}

final class SharedPreferencesLedgerPageSnapshotStore
    implements LedgerPageSnapshotStore {
  SharedPreferencesLedgerPageSnapshotStore._(this._preferences) {
    _hydrate();
  }

  static const String key = 'ledger.page.v1';

  final SharedPreferences _preferences;
  LedgerPageSnapshot? _snapshot;

  static Future<SharedPreferencesLedgerPageSnapshotStore> open() async =>
      SharedPreferencesLedgerPageSnapshotStore._(
          await SharedPreferences.getInstance());

  void _hydrate() {
    final raw = _preferences.getString(key);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final scope = decoded['scope'];
      final rawItems = decoded['items'];
      if (scope is! String || scope.isEmpty || rawItems is! List) return;
      final items = <Map<String, dynamic>>[];
      for (final row in rawItems) {
        if (row is! Map) continue;
        if (row['id'] is! String) continue;
        items.add(Map<String, dynamic>.unmodifiable(
            Map<String, dynamic>.from(row)));
      }
      if (items.isEmpty) return;
      final cursor = decoded['next_cursor'];
      _snapshot = LedgerPageSnapshot(
        scope: scope,
        items: items,
        nextCursor: cursor is String && cursor.isNotEmpty ? cursor : null,
        savedAt: DateTime.tryParse('${decoded['saved_at']}') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
    } catch (_) {
      // 损坏的快照按「无本地数据」处理并清掉，避免每次进入都解析失败。
      unawaited(_preferences.remove(key));
    }
  }

  @override
  LedgerPageSnapshot? read() => _snapshot;

  @override
  Future<void> write(LedgerPageSnapshot snapshot) async {
    _snapshot = snapshot;
    await _preferences.setString(
      key,
      jsonEncode({
        'scope': snapshot.scope,
        'items': snapshot.items,
        'next_cursor': snapshot.nextCursor,
        'saved_at': snapshot.savedAt.toUtc().toIso8601String(),
      }),
    );
  }

  @override
  Future<void> clear() async {
    _snapshot = null;
    await _preferences.remove(key);
  }
}

/// 进程级共享实例：由启动序列 `ensureLoaded()`，页面直接取用。
final class LedgerPageSnapshotStores {
  LedgerPageSnapshotStores._();

  static LedgerPageSnapshotStore? _shared;

  static LedgerPageSnapshotStore? get shared => _shared;

  static Future<LedgerPageSnapshotStore> ensureLoaded() async =>
      _shared ??= await SharedPreferencesLedgerPageSnapshotStore.open();

  @visibleForTesting
  static void reset() => _shared = null;

  @visibleForTesting
  static set shared(LedgerPageSnapshotStore? value) => _shared = value;
}
