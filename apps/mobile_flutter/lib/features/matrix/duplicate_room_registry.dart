import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 历史孤儿私聊房间登记簿（重复会话缺陷 0919 的配套设施）。
///
/// 保存服务端确认或账号同步的房间关联；本地活跃度不能覆盖权威映射。
/// m.direct 保留原始历史条目，本登记簿支持同一会话读取所有来源房间。
///
/// 用途（只记录、不删除）：
/// - `ConversationIdentityResolver` 的 primary 优先规则数据源；
/// - 未来数据迁移 / 历史检索 / 问题排查的台账。
///
/// 持久化按账号隔离。身份关联不是诊断缓存，不得按容量淘汰；业务接口与
/// Matrix account data 提供跨设备恢复，本地存储失败保留当前内存状态。
final class DuplicateRoomEntry {
  const DuplicateRoomEntry({
    required this.duplicateRoomId,
    required this.primaryRoomId,
    required this.peerId,
    required this.detectedAt,
  });

  factory DuplicateRoomEntry.fromJson(Map<String, Object?> json) =>
      DuplicateRoomEntry(
        duplicateRoomId: json['duplicate_room_id'] as String? ?? '',
        primaryRoomId: json['primary_room_id'] as String? ?? '',
        peerId: json['peer_id'] as String? ?? '',
        detectedAt: DateTime.tryParse(json['detected_at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );

  final String duplicateRoomId;
  final String primaryRoomId;
  final String peerId;
  final DateTime detectedAt;

  Map<String, Object?> toJson() => {
        'duplicate_room_id': duplicateRoomId,
        'primary_room_id': primaryRoomId,
        'peer_id': peerId,
        'detected_at': detectedAt.toIso8601String(),
      };
}

final class DuplicateRoomRegistry {
  DuplicateRoomRegistry({this.cap = 500});

  /// 兼容旧构造参数；身份映射不再受诊断缓存容量限制。
  final int cap;

  final Map<String, Map<String, DuplicateRoomEntry>> _byAccount = {};
  final Set<String> _loadedAccounts = {};
  final Map<String, Future<void>> _loads = {};
  final Map<String, Future<void>> _writes = {};
  final Map<String, Map<String, String>> _primaries = {};
  final Map<String, Map<String, int>> _revisions = {};
  final Map<String, Map<String, String>> _localIdentities = {};

  /// Projection identity is durable independently of the sending authority.
  /// Observing m.direct must never elect or overwrite a canonical destination.
  Future<void> rememberLocalIdentities(
      String accountId, Map<String, String> identities) async {
    await ensureLoaded(accountId);
    final retained = _localIdentities.putIfAbsent(accountId, () => {});
    var changed = false;
    for (final entry in identities.entries) {
      if (!entry.key.startsWith('!') ||
          (entry.value != 'group' &&
              (!entry.value.startsWith('@') || entry.value == accountId))) {
        continue;
      }
      if (retained[entry.key] == entry.value) continue;
      retained[entry.key] = entry.value;
      changed = true;
    }
    if (changed) await _persist(accountId);
  }

  bool isKnownGroup(String accountId, String roomId) =>
      _localIdentities[accountId]?[roomId] == 'group';

  Map<String, String> localDirectPeers(String accountId) => {
        for (final entry
            in (_localIdentities[accountId] ?? <String, String>{}).entries)
          if (entry.value.startsWith('@'))
            entry.key:
                verifiedPeerIdForRoom(accountId, entry.key) ?? entry.value,
      };

  Future<bool> rememberPrimary(String accountId, String peerId, String roomId,
      {int? revision}) async {
    if (accountId.isEmpty ||
        peerId.isEmpty ||
        roomId.isEmpty ||
        (revision != null && revision < 0)) {
      return false;
    }
    await ensureLoaded(accountId);
    final previousRoom = _primaries[accountId]?[peerId];
    final previousRevision = _revisions[accountId]?[peerId];
    if (previousRevision != null &&
        ((revision == null && previousRoom != roomId) ||
            (revision != null &&
                (revision < previousRevision ||
                    (revision == previousRevision &&
                        previousRoom != roomId))))) {
      return false;
    }
    if (previousRoom == roomId &&
        (revision == null || revision == previousRevision)) {
      return true;
    }
    _primaries.putIfAbsent(accountId, () => {})[peerId] = roomId;
    if (revision != null) {
      _revisions.putIfAbsent(accountId, () => {})[peerId] = revision;
    }
    if (previousRoom != null && previousRoom != roomId) {
      _byAccount.putIfAbsent(accountId, () => {})[previousRoom] =
          DuplicateRoomEntry(
              duplicateRoomId: previousRoom,
              primaryRoomId: roomId,
              peerId: peerId,
              detectedAt: DateTime.now().toUtc());
    }
    final entries = _byAccount[accountId];
    if (entries != null) {
      entries.remove(roomId);
      for (final entry in entries.values.toList()) {
        if (entry.peerId != peerId) continue;
        entries[entry.duplicateRoomId] = DuplicateRoomEntry(
            duplicateRoomId: entry.duplicateRoomId,
            primaryRoomId: roomId,
            peerId: peerId,
            detectedAt: entry.detectedAt);
      }
    }
    await _persist(accountId);
    return true;
  }

  int? revisionForPeer(String accountId, String peerId) =>
      _revisions[accountId]?[peerId];

  static const _prefix = 'duplicate-room-registry-v1:';

  String _key(String accountId) => '$_prefix${Uri.encodeComponent(accountId)}';

  /// 从持久层装载（幂等：同账号只读一次盘；record 写穿内存 + 持久层）。
  Future<void> ensureLoaded(String accountId) {
    if (accountId.isEmpty || _loadedAccounts.contains(accountId)) {
      return Future.value();
    }
    return _loads.putIfAbsent(accountId, () => _load(accountId));
  }

  Future<void> _load(String accountId) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_key(accountId));
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      final list =
          decoded is List ? decoded : (decoded as Map)['entries'] as List;
      final entries = _byAccount.putIfAbsent(accountId, () => {});
      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        try {
          final entry = DuplicateRoomEntry.fromJson(item);
          if (entry.duplicateRoomId.isEmpty ||
              entry.primaryRoomId.isEmpty ||
              entry.peerId.isEmpty) {
            continue;
          }
          entries.putIfAbsent(entry.duplicateRoomId, () => entry);
        } catch (_) {
          /* One damaged record must not discard other identities. */
        }
      }
      if (decoded is Map && decoded['primaries'] is Map) {
        final primaries = _primaries.putIfAbsent(accountId, () => {});
        for (final entry in (decoded['primaries'] as Map).entries) {
          if (entry.key is String && entry.value is String) {
            primaries.putIfAbsent(
                entry.key as String, () => entry.value as String);
          }
        }
      }
      if (decoded is Map && decoded['revisions'] is Map) {
        final revisions = _revisions.putIfAbsent(accountId, () => {});
        for (final entry in (decoded['revisions'] as Map).entries) {
          if (entry.key is String &&
              entry.value is int &&
              entry.value >= 0 &&
              _primaries[accountId]?.containsKey(entry.key) == true) {
            revisions.putIfAbsent(
                entry.key as String, () => entry.value as int);
          }
        }
      }
      if (decoded is Map && decoded['local_identities'] is Map) {
        final identities = _localIdentities.putIfAbsent(accountId, () => {});
        for (final entry in (decoded['local_identities'] as Map).entries) {
          if (entry.key is String &&
              (entry.key as String).startsWith('!') &&
              entry.value is String &&
              (entry.value == 'group' ||
                  ((entry.value as String).startsWith('@') &&
                      entry.value != accountId))) {
            identities.putIfAbsent(
                entry.key as String, () => entry.value as String);
          }
        }
      }
    } catch (_) {
      // 持久层不可用：登记退化为进程内内存（不阻断收敛/解析）。
    } finally {
      _loadedAccounts.add(accountId);
      _loads.remove(accountId);
    }
  }

  /// 登记一个重复房间（[duplicateRoomId] 展示上让位给 [primaryRoomId]）。
  /// 只改登记簿，绝不触碰房间本身。
  Future<void> record({
    required String accountId,
    required String peerId,
    required String primaryRoomId,
    required String duplicateRoomId,
    int? revision,
  }) async {
    if (accountId.isEmpty ||
        peerId.isEmpty ||
        primaryRoomId.isEmpty ||
        duplicateRoomId.isEmpty ||
        primaryRoomId == duplicateRoomId) {
      return;
    }
    await ensureLoaded(accountId);
    await rememberPrimary(accountId, peerId, primaryRoomId, revision: revision);
    final effectivePrimary = _primaries[accountId]?[peerId];
    if (effectivePrimary == null || duplicateRoomId == effectivePrimary) return;
    final entries =
        _byAccount.putIfAbsent(accountId, () => <String, DuplicateRoomEntry>{});
    final old = entries[duplicateRoomId];
    if (old?.peerId == peerId && old?.primaryRoomId == effectivePrimary) return;
    entries.remove(duplicateRoomId);
    entries[duplicateRoomId] = DuplicateRoomEntry(
      duplicateRoomId: duplicateRoomId,
      primaryRoomId: effectivePrimary,
      peerId: peerId,
      detectedAt: DateTime.now().toUtc(),
    );
    await _persist(accountId);
  }

  /// 该 peer 当前登记的 primary 房间（无登记返回 null）。纯内存查询。
  String? primaryRoomIdForPeer(String accountId, String peerId) {
    final known = _primaries[accountId]?[peerId];
    if (known != null) return known;
    final entries = _byAccount[accountId];
    if (entries == null) return null;
    for (final entry in entries.values) {
      if (entry.peerId == peerId) return entry.primaryRoomId;
    }
    return null;
  }

  /// 反查：roomId 是否是登记在案的重复房间（是则返回其条目，含 peerId
  /// 与 primaryRoomId）。收敛把旧房间移出 m.direct 后，快照/搜索/通知
  /// 都靠它恢复旧房间的私聊身份。
  DuplicateRoomEntry? entryForRoom(String accountId, String roomId) =>
      _byAccount[accountId]?[roomId];

  String? peerIdForRoom(String accountId, String roomId) {
    final verified = verifiedPeerIdForRoom(accountId, roomId);
    if (verified != null) return verified;
    final local = _localIdentities[accountId]?[roomId];
    return local?.startsWith('@') == true ? local : null;
  }

  String? verifiedPeerIdForRoom(String accountId, String roomId) {
    final duplicate = entryForRoom(accountId, roomId);
    if (duplicate != null) return duplicate.peerId;
    for (final entry in (_primaries[accountId] ?? <String, String>{}).entries) {
      if (entry.value == roomId) return entry.key;
    }
    return null;
  }

  /// 反查便捷形式：重复房间的 primary 房间号（非重复房间返回 null）。
  String? primaryRoomIdForDuplicate(String accountId, String roomId) =>
      entryForRoom(accountId, roomId)?.primaryRoomId;

  List<DuplicateRoomEntry> entries(String accountId) =>
      switch (_byAccount[accountId]) {
        final entries? => List.unmodifiable(entries.values),
        _ => const [],
      };

  Future<void> _persist(String accountId) {
    final previous = _writes[accountId] ?? Future<void>.value();
    final write = previous.then((_) => _write(accountId));
    _writes[accountId] = write;
    return write;
  }

  Future<void> _write(String accountId) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        _key(accountId),
        jsonEncode({
          'entries': [
            for (final entry
                in _byAccount[accountId]?.values ?? <DuplicateRoomEntry>[])
              entry.toJson()
          ],
          'primaries': _primaries[accountId] ?? <String, String>{},
          'revisions': _revisions[accountId] ?? <String, int>{},
          'local_identities': _localIdentities[accountId] ?? <String, String>{},
        }),
      );
    } catch (_) {
      // 存储失败不回滚内存；下一次账号/服务端同步仍能恢复关联。
    }
  }

  /// 测试专用：清空内存与已装载标记。
  void resetForTest() {
    _byAccount.clear();
    _primaries.clear();
    _revisions.clear();
    _localIdentities.clear();
    _loadedAccounts.clear();
    _loads.clear();
    _writes.clear();
  }
}
