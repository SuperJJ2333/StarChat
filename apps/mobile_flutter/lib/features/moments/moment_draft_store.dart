import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 朋友圈草稿的本地快照。
///
/// 微信级加载模型：草稿此前只存在服务端（`api.momentDraft()`），断网时既读不到
/// 上次的草稿，写了也留不下——发动态页一关就全丢。这里把草稿在本地留一份
/// （账号作用域），进入发布页时先渲染本地草稿，再后台与服务端对齐。
@immutable
final class MomentDraftSnapshot {
  const MomentDraftSnapshot({
    required this.scope,
    required this.payload,
    required this.savedAt,
  });

  /// 账号作用域（`matrix:<matrixUserId>`）；账号切换即失效，草稿绝不跨账号展示。
  final String scope;
  final Map<String, dynamic> payload;
  final DateTime savedAt;
}

abstract interface class MomentDraftStore {
  /// 同步读取：发布页首帧就要用。
  MomentDraftSnapshot? read();

  Future<void> write(MomentDraftSnapshot snapshot);

  Future<void> clear();
}

final class InMemoryMomentDraftStore implements MomentDraftStore {
  InMemoryMomentDraftStore([this._snapshot]);

  MomentDraftSnapshot? _snapshot;

  @override
  MomentDraftSnapshot? read() => _snapshot;

  @override
  Future<void> write(MomentDraftSnapshot snapshot) async {
    _snapshot = snapshot;
  }

  @override
  Future<void> clear() async {
    _snapshot = null;
  }
}

final class SharedPreferencesMomentDraftStore implements MomentDraftStore {
  SharedPreferencesMomentDraftStore._(this._preferences) {
    _hydrate();
  }

  static const String key = 'moment.draft.v1';

  final SharedPreferences _preferences;
  MomentDraftSnapshot? _snapshot;

  static Future<SharedPreferencesMomentDraftStore> open() async =>
      SharedPreferencesMomentDraftStore._(await SharedPreferences.getInstance());

  void _hydrate() {
    final raw = _preferences.getString(key);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final scope = decoded['scope'];
      final payload = decoded['payload'];
      if (scope is! String || scope.isEmpty || payload is! Map) return;
      _snapshot = MomentDraftSnapshot(
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
  MomentDraftSnapshot? read() => _snapshot;

  @override
  Future<void> write(MomentDraftSnapshot snapshot) async {
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

/// 进程级共享实例：启动序列 `ensureLoaded()`，发布页直接取用。
final class MomentDraftStores {
  MomentDraftStores._();

  static MomentDraftStore? _shared;

  static MomentDraftStore? get shared => _shared;

  static Future<MomentDraftStore> ensureLoaded() async =>
      _shared ??= await SharedPreferencesMomentDraftStore.open();

  @visibleForTesting
  static void reset() => _shared = null;

  @visibleForTesting
  static set shared(MomentDraftStore? value) => _shared = value;
}
