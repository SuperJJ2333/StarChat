import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 邀请码页（个人邀请码 + 邀请历史首页）的本地快照。
///
/// 微信级加载模型要求「本地优先 → 立即展示 → 后台同步 → 失败不覆盖」。
/// `InviteCodeController` 原先每次进入都先 `status = loading` 再发请求，失败还会
/// 把「邀请码加载失败，请重试」盖在屏幕上；邀请历史刷新更是先 `clearHistory`，
/// 于是弱网/断网时页面上什么都留不住，联网时也要先闪一次加载圈。
/// 这里把**最后一次成功的邀请码与邀请历史首页**落本地，进入时先水合。
///
/// 只缓存展示数据（邀请码、可用次数、分享链接、邀请历史首页的昵称/畅聊号），
/// 不缓存任何凭据；快照带账号作用域，读取方必须校验，账号切换后立即丢弃，
/// 邀请码与受邀好友绝不跨账号展示。
@immutable
final class InviteSnapshot {
  const InviteSnapshot({
    required this.scope,
    required this.code,
    required this.maxUses,
    required this.useCount,
    required this.shareUrl,
    required this.history,
    required this.historyNextOffset,
    required this.savedAt,
  });

  /// 该快照属于哪个账号作用域。
  final String scope;
  final String code;
  final int maxUses;
  final int useCount;
  final String shareUrl;

  /// 邀请历史首页（可能为空：服务端确实没有邀请记录时不落盘，见控制器）。
  final List<Map<String, dynamic>> history;
  final int? historyNextOffset;
  final DateTime savedAt;
}

abstract interface class InviteSnapshotStore {
  /// 同步读取：页面首帧就要用，不能等异步 IO。
  InviteSnapshot? read();

  Future<void> write(InviteSnapshot snapshot);

  Future<void> clear();
}

/// 本地快照作用域来源（账号维度）。
///
/// 与账单页一致：作用域不可解析（未登录、令牌不可读）时返回 `null`，
/// 调用方保守处理——不落盘、并丢弃无法校验的旧快照。
abstract interface class InviteCacheScopeProvider {
  Future<String?> inviteCacheScope();
}

final class InMemoryInviteSnapshotStore implements InviteSnapshotStore {
  InMemoryInviteSnapshotStore([this._snapshot]);

  InviteSnapshot? _snapshot;

  @override
  InviteSnapshot? read() => _snapshot;

  @override
  Future<void> write(InviteSnapshot snapshot) async {
    _snapshot = snapshot;
  }

  @override
  Future<void> clear() async {
    _snapshot = null;
  }
}

final class SharedPreferencesInviteSnapshotStore implements InviteSnapshotStore {
  SharedPreferencesInviteSnapshotStore._(this._preferences) {
    _hydrate();
  }

  static const String key = 'invite.code.v1';

  final SharedPreferences _preferences;
  InviteSnapshot? _snapshot;

  static Future<SharedPreferencesInviteSnapshotStore> open() async =>
      SharedPreferencesInviteSnapshotStore._(
          await SharedPreferences.getInstance());

  void _hydrate() {
    final raw = _preferences.getString(key);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final scope = decoded['scope'];
      final code = decoded['code'];
      if (scope is! String || scope.isEmpty) return;
      if (code is! String || code.isEmpty) return;
      final history = <Map<String, dynamic>>[];
      final rawHistory = decoded['history'];
      if (rawHistory is List) {
        for (final row in rawHistory) {
          if (row is! Map) continue;
          if (row['username'] is! String) continue;
          history.add(Map<String, dynamic>.unmodifiable(
              Map<String, dynamic>.from(row)));
        }
      }
      final next = decoded['history_next_offset'];
      _snapshot = InviteSnapshot(
        scope: scope,
        code: code,
        maxUses: (decoded['max_uses'] as num?)?.toInt() ?? 0,
        useCount: (decoded['use_count'] as num?)?.toInt() ?? 0,
        shareUrl: '${decoded['share_url'] ?? ''}',
        history: history,
        historyNextOffset: next is num ? next.toInt() : null,
        savedAt: DateTime.tryParse('${decoded['saved_at']}') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
    } catch (_) {
      // 损坏的快照按「无本地数据」处理并清掉，避免每次进入都解析失败。
      unawaited(_preferences.remove(key));
    }
  }

  @override
  InviteSnapshot? read() => _snapshot;

  @override
  Future<void> write(InviteSnapshot snapshot) async {
    _snapshot = snapshot;
    await _preferences.setString(
      key,
      jsonEncode({
        'scope': snapshot.scope,
        'code': snapshot.code,
        'max_uses': snapshot.maxUses,
        'use_count': snapshot.useCount,
        'share_url': snapshot.shareUrl,
        'history': snapshot.history,
        'history_next_offset': snapshot.historyNextOffset,
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

/// 进程级共享实例：控制器首次构造时按需打开（`ensureLoaded()`）。
final class InviteSnapshotStores {
  InviteSnapshotStores._();

  static InviteSnapshotStore? _shared;

  static InviteSnapshotStore? get shared => _shared;

  static Future<InviteSnapshotStore> ensureLoaded() async =>
      _shared ??= await SharedPreferencesInviteSnapshotStore.open();

  @visibleForTesting
  static void reset() => _shared = null;

  @visibleForTesting
  static set shared(InviteSnapshotStore? value) => _shared = value;
}
