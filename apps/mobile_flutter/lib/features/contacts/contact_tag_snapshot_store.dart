import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 通讯录标签列表的本地快照（按账号隔离）。
///
/// 微信级加载模型（2026-09-19 审计 L1 缺口）：`ContactTagsPage` 原先只有
/// `contactTags()` 一个网络数据源，冷启动断网时既没有标签可看，也没有任何
/// 上次结果可回退。这里把最后一次成功的 `/contacts/tags` 负载落盘，进入时
/// 同步水合，首帧即展示；刷新失败保留数据。
@immutable
final class ContactTagSnapshot {
  const ContactTagSnapshot({
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

abstract interface class ContactTagSnapshotStore {
  /// 同步读取：首帧就要用。
  ContactTagSnapshot? read();

  Future<void> write(ContactTagSnapshot snapshot);

  Future<void> clear();
}

final class InMemoryContactTagSnapshotStore
    implements ContactTagSnapshotStore {
  InMemoryContactTagSnapshotStore([ContactTagSnapshot? snapshot]) : _snapshot = snapshot;

  ContactTagSnapshot? _snapshot;

  @override
  ContactTagSnapshot? read() => _snapshot;

  @override
  Future<void> write(ContactTagSnapshot snapshot) async {
    _snapshot = snapshot;
  }

  @override
  Future<void> clear() async {
    _snapshot = null;
  }
}

final class SharedPreferencesContactTagSnapshotStore
    implements ContactTagSnapshotStore {
  SharedPreferencesContactTagSnapshotStore._(this._preferences) {
    _hydrate();
  }

  static const String key = 'contact.tags.v1';

  final SharedPreferences _preferences;
  ContactTagSnapshot? _snapshot;

  static Future<SharedPreferencesContactTagSnapshotStore> open() async =>
      SharedPreferencesContactTagSnapshotStore._(
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
      _snapshot = ContactTagSnapshot(
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
  ContactTagSnapshot? read() => _snapshot;

  @override
  Future<void> write(ContactTagSnapshot snapshot) async {
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
final class ContactTagSnapshotStores {
  ContactTagSnapshotStores._();

  static ContactTagSnapshotStore? _shared;

  static ContactTagSnapshotStore? get shared => _shared;

  static Future<ContactTagSnapshotStore> ensureLoaded() async =>
      _shared ??= await SharedPreferencesContactTagSnapshotStore.open();

  @visibleForTesting
  static void reset() => _shared = null;

  @visibleForTesting
  static set shared(ContactTagSnapshotStore? value) => _shared = value;
}
