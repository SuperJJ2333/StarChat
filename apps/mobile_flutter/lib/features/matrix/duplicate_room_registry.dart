import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 历史孤儿私聊房间登记簿（重复会话缺陷 0919 的配套设施）。
///
/// `DirectRoomDirectoryConvergence` 收敛 m.direct 时，把被落选（隐藏展示）
/// 的重复房间登记到这里；服务端 canonical 裁决的 primary 房间是唯一登记
/// 来源——本地规则选出的落选者不登记，避免用弱证据覆盖权威映射。
///
/// 用途（只记录、不删除）：
/// - `ConversationIdentityResolver` 的 primary 优先规则数据源；
/// - 未来数据迁移 / 历史检索 / 问题排查的台账。
///
/// 持久化：SharedPreferences 按账号一个 JSON 列表；数量有 [cap] 上限，
/// 超限淘汰最旧的登记。任何存储失败都不阻断调用方（登记是尽力而为）。
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
        detectedAt:
            DateTime.tryParse(json['detected_at'] as String? ?? '') ??
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

  /// 每账号登记上限：防跨会话无限膨胀；超限按 detectedAt 最旧淘汰。
  final int cap;

  final Map<String, Map<String, DuplicateRoomEntry>> _byAccount = {};
  final Set<String> _loadedAccounts = {};

  static const _prefix = 'duplicate-room-registry-v1:';

  String _key(String accountId) =>
      '$_prefix${Uri.encodeComponent(accountId)}';

  /// 从持久层装载（幂等：同账号只读一次盘；record 写穿内存 + 持久层）。
  Future<void> ensureLoaded(String accountId) async {
    if (accountId.isEmpty || _loadedAccounts.contains(accountId)) return;
    _loadedAccounts.add(accountId);
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_key(accountId));
      if (raw == null || raw.isEmpty) return;
      final list = (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
      _byAccount[accountId] = {
        for (final item in list)
          if (item['duplicate_room_id'] is String)
            item['duplicate_room_id'] as String: DuplicateRoomEntry.fromJson(item),
      };
    } catch (_) {
      // 持久层不可用：登记退化为进程内内存（不阻断收敛/解析）。
    }
  }

  /// 登记一个重复房间（[duplicateRoomId] 展示上让位给 [primaryRoomId]）。
  /// 只改登记簿，绝不触碰房间本身。
  Future<void> record({
    required String accountId,
    required String peerId,
    required String primaryRoomId,
    required String duplicateRoomId,
  }) async {
    if (accountId.isEmpty ||
        primaryRoomId.isEmpty ||
        duplicateRoomId.isEmpty ||
        primaryRoomId == duplicateRoomId) {
      return;
    }
    final entries =
        _byAccount.putIfAbsent(accountId, () => <String, DuplicateRoomEntry>{});
    entries.remove(duplicateRoomId);
    entries[duplicateRoomId] = DuplicateRoomEntry(
      duplicateRoomId: duplicateRoomId,
      primaryRoomId: primaryRoomId,
      peerId: peerId,
      detectedAt: DateTime.now().toUtc(),
    );
    await _persist(accountId);
  }

  /// 该 peer 当前登记的 primary 房间（无登记返回 null）。纯内存查询。
  String? primaryRoomIdForPeer(String accountId, String peerId) {
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

  /// 反查便捷形式：重复房间的 primary 房间号（非重复房间返回 null）。
  String? primaryRoomIdForDuplicate(String accountId, String roomId) =>
      entryForRoom(accountId, roomId)?.primaryRoomId;

  List<DuplicateRoomEntry> entries(String accountId) =>
      switch (_byAccount[accountId]) {
        final entries? => List.unmodifiable(entries.values),
        _ => const [],
      };

  Future<void> _persist(String accountId) async {
    final entries = _byAccount[accountId];
    if (entries == null) return;
    // 超限淘汰最旧的登记（detectedAt 升序），保证存储有界。
    final ordered = entries.values.toList()
      ..sort((a, b) => a.detectedAt.compareTo(b.detectedAt));
    while (ordered.length > cap) {
      final evicted = ordered.removeAt(0);
      if (identical(entries[evicted.duplicateRoomId], evicted)) {
        entries.remove(evicted.duplicateRoomId);
      }
    }
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        _key(accountId),
        jsonEncode([for (final entry in ordered) entry.toJson()]),
      );
    } catch (_) {
      // 存储失败不回滚内存：登记是排查台账，不是一致性关键数据。
    }
  }

  /// 测试专用：清空内存与已装载标记。
  void resetForTest() {
    _byAccount.clear();
    _loadedAccounts.clear();
  }
}
