import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「新的朋友」列表的本地快照（按账号隔离）。
///
/// 微信级加载模型：该页面原先只有 `Future<Map>` 一个数据源，加载中与失败时
/// `snapshot.data` 都是 null，于是**两种情况都渲染「暂无新的朋友」** —— 用户看到
/// 的不是"还在加载/加载失败"，而是"没有新朋友"，断网时更是把上一份真实列表丢掉。
/// 这里把最后一次成功的 `/friends/requests` 负载落盘，进入时同步水合，首帧即展示。
@immutable
final class FriendRequestSnapshot {
  const FriendRequestSnapshot({
    required this.scope,
    required this.payload,
    required this.savedAt,
  });

  /// 账号作用域（`matrix:<matrixUserId>`）。账号切换后立即失效。
  final String scope;

  /// 服务端原样负载（`{items: [...]}`）。
  final Map<String, dynamic> payload;
  final DateTime savedAt;
}

abstract interface class FriendRequestSnapshotStore {
  /// 同步读取：首帧就要用。
  FriendRequestSnapshot? read();

  Future<void> write(FriendRequestSnapshot snapshot);

  Future<void> clear();
}

final class InMemoryFriendRequestSnapshotStore
    implements FriendRequestSnapshotStore {
  InMemoryFriendRequestSnapshotStore([this._snapshot]);

  FriendRequestSnapshot? _snapshot;

  @override
  FriendRequestSnapshot? read() => _snapshot;

  @override
  Future<void> write(FriendRequestSnapshot snapshot) async {
    _snapshot = snapshot;
  }

  @override
  Future<void> clear() async {
    _snapshot = null;
  }
}

final class SharedPreferencesFriendRequestSnapshotStore
    implements FriendRequestSnapshotStore {
  SharedPreferencesFriendRequestSnapshotStore._(this._preferences) {
    _hydrate();
  }

  static const String key = 'friend.requests.v1';

  final SharedPreferences _preferences;
  FriendRequestSnapshot? _snapshot;

  static Future<SharedPreferencesFriendRequestSnapshotStore> open() async =>
      SharedPreferencesFriendRequestSnapshotStore._(
          await SharedPreferences.getInstance());

  void _hydrate() {
    final raw = _preferences.getString(key);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final scope = decoded['scope'];
      final payload = decoded['payload'];
      if (scope is! String || scope.isEmpty || payload is! Map) return;
      final items = payload['items'];
      if (items is! List || items.isEmpty) return;
      _snapshot = FriendRequestSnapshot(
        scope: scope,
        payload: Map<String, dynamic>.unmodifiable(
            Map<String, dynamic>.from(payload)),
        savedAt: DateTime.tryParse('${decoded['saved_at']}') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
    } catch (_) {
      unawaited(_preferences.remove(key));
    }
  }

  @override
  FriendRequestSnapshot? read() => _snapshot;

  @override
  Future<void> write(FriendRequestSnapshot snapshot) async {
    _snapshot = snapshot;
    await _preferences.setString(
      key,
      jsonEncode({
        'scope': snapshot.scope,
        'payload': snapshot.payload,
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

/// 进程级共享实例：启动序列 `ensureLoaded()`，页面直接取用。
final class FriendRequestSnapshotStores {
  FriendRequestSnapshotStores._();

  static FriendRequestSnapshotStore? _shared;

  static FriendRequestSnapshotStore? get shared => _shared;

  static Future<FriendRequestSnapshotStore> ensureLoaded() async =>
      _shared ??= await SharedPreferencesFriendRequestSnapshotStore.open();

  @visibleForTesting
  static void reset() => _shared = null;

  @visibleForTesting
  static set shared(FriendRequestSnapshotStore? value) => _shared = value;
}
