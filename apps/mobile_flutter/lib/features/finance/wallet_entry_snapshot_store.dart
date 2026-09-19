import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 钱包进入态的**本地快照**。
///
/// 存在的理由（用户报告 2026-09-19）：`WalletEntryStore` 的缓存原始实现只在进程内存
/// 里，App 一重启就没了，于是每个钱包子页面（钱包/点钻/充值/提现）在每次启动后都要
/// 重走一遍「空态 → 请求失败短暂弹错 → 有网才恢复」；断网时更是连余额、绑定信息与
/// 能力位（能否充值/提现）都拿不到，入口直接不可用。微信级加载模型要求「本地优先 →
/// 立即展示 → 后台同步 → 失败不覆盖」，本地这一层必须跨进程存活。
///
/// 存储位置与边界：
/// - 应用私有 SharedPreferences，键前缀 `wallet.entry.v1.`，键里带**账号作用域**
///   （`<origin>:<subject>`，点钻页为 `<scope>#caibi`），因此不同账号天然隔离；
/// - 只存展示所需的服务端快照（能力配置 + 余额；点钻页另含最近流水与月度汇总），
///   不存 access token、验证码、恢复密钥或任何凭据——凭据仍只在 `SecureSessionStore`；
/// - 账号切换（session epoch 变化）立即清除该作用域快照，金融数据绝不跨账号展示。
@immutable
final class WalletEntrySnapshot {
  const WalletEntrySnapshot({required this.data, required this.savedAt});

  final Map<String, dynamic> data;
  final DateTime savedAt;
}

/// 快照存储。`read` 必须是**同步**的：页面首帧就要拿到数据，不能等异步 IO。
abstract interface class WalletEntrySnapshotStore {
  WalletEntrySnapshot? read(String scope);

  Future<void> write(String scope, WalletEntrySnapshot snapshot);

  Future<void> clear(String scope);

  Future<void> clearAll();
}

/// 测试与降级路径使用的内存实现（不落盘，语义与持久化实现一致）。
final class InMemoryWalletEntrySnapshotStore
    implements WalletEntrySnapshotStore {
  InMemoryWalletEntrySnapshotStore(
      [Map<String, WalletEntrySnapshot>? seed])
      : _entries = {...?seed};

  final Map<String, WalletEntrySnapshot> _entries;

  @override
  WalletEntrySnapshot? read(String scope) => _entries[scope];

  @override
  Future<void> write(String scope, WalletEntrySnapshot snapshot) async {
    _entries[scope] = snapshot;
  }

  @override
  Future<void> clear(String scope) async {
    _entries.remove(scope);
  }

  @override
  Future<void> clearAll() async {
    _entries.clear();
  }
}

/// SharedPreferences 实现：`open()` 时把全部快照读进内存，之后 `read` 同步命中。
final class SharedPreferencesWalletEntrySnapshotStore
    implements WalletEntrySnapshotStore {
  SharedPreferencesWalletEntrySnapshotStore._(this._preferences) {
    _hydrate();
  }

  static const String prefix = 'wallet.entry.v1.';

  final SharedPreferences _preferences;
  final Map<String, WalletEntrySnapshot> _entries =
      <String, WalletEntrySnapshot>{};

  static Future<SharedPreferencesWalletEntrySnapshotStore> open() async =>
      SharedPreferencesWalletEntrySnapshotStore._(
          await SharedPreferences.getInstance());

  void _hydrate() {
    for (final key in _preferences.getKeys().toList(growable: false)) {
      if (!key.startsWith(prefix)) continue;
      final raw = _preferences.getString(key);
      if (raw == null || raw.isEmpty) continue;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) continue;
        final data = decoded['data'];
        if (data is! Map) continue;
        _entries[key.substring(prefix.length)] = WalletEntrySnapshot(
          data: Map<String, dynamic>.from(data),
          savedAt: DateTime.tryParse('${decoded['saved_at']}') ??
              DateTime.fromMillisecondsSinceEpoch(0),
        );
      } catch (_) {
        // 损坏的快照按「无本地数据」处理，并顺手清掉，避免每次启动都解析失败。
        unawaited(_preferences.remove(key));
      }
    }
  }

  @override
  WalletEntrySnapshot? read(String scope) => _entries[scope];

  @override
  Future<void> write(String scope, WalletEntrySnapshot snapshot) async {
    _entries[scope] = snapshot;
    await _preferences.setString(
      '$prefix$scope',
      jsonEncode({
        'data': snapshot.data,
        'saved_at': snapshot.savedAt.toUtc().toIso8601String(),
      }),
    );
  }

  @override
  Future<void> clear(String scope) async {
    _entries.remove(scope);
    await _preferences.remove('$prefix$scope');
  }

  @override
  Future<void> clearAll() async {
    _entries.clear();
    for (final key in _preferences.getKeys().toList(growable: false)) {
      if (key.startsWith(prefix)) await _preferences.remove(key);
    }
  }
}

/// 进程级共享快照存储。页面不需要自己接线：`WalletEntryStores.of()` 会取这里。
final class WalletEntrySnapshotStores {
  WalletEntrySnapshotStores._();

  static WalletEntrySnapshotStore? _shared;

  static WalletEntrySnapshotStore? get shared => _shared;

  /// 在应用启动序列里 await 一次，之后所有 `read` 都是同步命中。
  static Future<WalletEntrySnapshotStore> ensureLoaded() async =>
      _shared ??= await SharedPreferencesWalletEntrySnapshotStore.open();

  @visibleForTesting
  static void reset() => _shared = null;
}
