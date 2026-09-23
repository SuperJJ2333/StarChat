import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'global_search_models.dart';

/// 一条已解密的本地消息记录（仅 metadata + 正文，本机内存）。
@immutable
final class GlobalSearchMessageRecord {
  const GlobalSearchMessageRecord({
    required this.eventId,
    required this.senderId,
    required this.senderName,
    required this.timestamp,
    required this.body,
    this.senderIsSelf = false,
  });

  final String eventId;
  final String senderId;
  final String senderName;
  final DateTime timestamp;

  /// 已解密正文；仅在设备本地内存参与匹配。
  final String body;
  final bool senderIsSelf;
}

/// 设备侧搜索索引（**可从本机加密 Matrix DB 重建**；不落盘、不上传、
/// 不含 room key / 密文 / 明文附件）。
///
/// 命名与边界（务必如实理解，**不要**把它描述成持久化明文索引）：
/// - 本类是 **in-memory、可重建** 的设备侧搜索索引。真正的持久数据源是设备的
///   **SQLCipher 加密 Matrix 数据库**（经 `LocalMessageSearchRepository` 的
///   `LocalHistorySearchSource` 读取）；本类自身不做任何落盘；
/// - 它不是 `PersistentGlobalSearchIndex`：进程重启后内容由本机加密库重新
///   回填得到，因此「重启后仍能搜索」靠的是加密库，而不是索引落盘；
/// - 只索引「本机已解密的、用户可见的」消息；未解密/被锁定的加密正文永不
///   进入；闪照与媒体占位正文在入库前被过滤；
/// - 生命周期与账号会话一致（内存）；账号切换/登出必须清空（[clear]）。
///
/// 数据来源：(a) 本机加密 Matrix 库的历史回填 + (b) 用户打开过的房间时间线
/// （RoomPage 增量投影）。因此它是「本机已有历史」的搜索，既不是「云端全量
/// 历史」，也不是「本次进程内打开过的房间」的搜索。
///
/// [maxRecordsPerRoom] 是**内存安全阀**，不是产品语义上限：它必须远高于
/// 旧实现硬编码的 4000，否则本机已有历史会被永久截断而不可检索。
/// 需要「更早的历史」时用 [search] 的 [limit]/[offset] 分页，而不是加索引上限。
final class GlobalSearchIndex {
  GlobalSearchIndex({this.maxRooms = 200, this.maxRecordsPerRoom = 40000});

  final int maxRooms;

  /// 单房间内存安全阀（默认 40000；旧的 4000 会把本机历史永久截断）。
  final int maxRecordsPerRoom;
  final Map<String, _IndexedRoom> _rooms = <String, _IndexedRoom>{};
  int _accountEpoch = 0;

  /// 当前账号代次（账号切换时索引必须清空，不得跨账号泄漏）。
  ///
  /// 生产代码（[LocalMessageSearchRepository]）用它丢弃切换账号后迟到的回填结果。
  int get accountEpoch => _accountEpoch;

  @visibleForTesting
  int get indexedRoomCount => _rooms.length;

  /// 记录一个房间的本地投影。
  ///
  /// [replace] = true（默认）：用 [messages] 覆盖该房间的既有记录；
  /// [replace] = false：与既有记录**合并**（按 eventId 去重，新时间优先），
  /// 用于「回填本机历史 + 后续增量同步」的场景，避免新的一页把更早的历史挤掉。
  /// 无论哪种模式，都只保留最近 [maxRecordsPerRoom] 条（内存安全阀）。
  void recordRoom({
    required String roomId,
    required String roomName,
    required bool isGroup,
    required Iterable<GlobalSearchMessageRecord> messages,
    String? roomAvatarSeed,
    String? roomAvatarUrl,
    bool replace = true,
  }) {
    if (roomId.isEmpty) return;
    final old = replace ? null : _rooms[roomId];
    final room = _IndexedRoom(
      roomId: roomId,
      roomName: roomName,
      isGroup: isGroup,
      avatarSeed: roomAvatarSeed,
      avatarUrl: roomAvatarUrl,
      records: old?.records ?? {},
      order: old?.order ?? SplayTreeMap<_RecordOrder, String>(_compareOrder),
    );
    for (final record in messages) {
      if (record.eventId.isEmpty || record.body.trim().isEmpty) continue;
      final previous = room.records[record.eventId];
      if (previous != null) {
        room.order.remove((previous.timestamp, previous.eventId));
      }
      room.records[record.eventId] = record;
      room.order[(record.timestamp, record.eventId)] = record.eventId;
      while (room.records.length > maxRecordsPerRoom) {
        final oldest = room.order.firstKey()!;
        room.records.remove(room.order.remove(oldest));
      }
    }
    _rooms.remove(roomId); // LRU without re-sorting/copying all old records.
    _rooms[roomId] = room;
    while (_rooms.length > maxRooms) {
      _rooms.remove(_rooms.keys.first);
    }
  }

  /// Recalls update both indexes without scanning every message in every room.
  int removeMessages(Iterable<String> eventIds) {
    final ids = Set<String>.of(eventIds);
    if (ids.isEmpty) return 0;
    var removed = 0;
    _rooms.removeWhere((_, room) {
      for (final id in ids) {
        final record = room.records.remove(id);
        if (record == null) continue;
        room.order.remove((record.timestamp, record.eventId));
        removed++;
      }
      return room.records.isEmpty;
    });
    return removed;
  }

  /// 按关键词检索（连续子串、英文忽略大小写、中文按字），最近优先。
  ///
  /// [limit] 单次结果上限；[offset] 用于分页取更早的命中（越界返回空）。
  List<GlobalSearchMessageHit> search(String query,
      {int limit = 200, int offset = 0}) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    final hits = <GlobalSearchMessageHit>[];
    for (final room in _rooms.values) {
      for (final record in room.records.values) {
        if (!record.body.toLowerCase().contains(needle)) continue;
        hits.add(GlobalSearchMessageHit(
          roomId: room.roomId,
          roomName: room.roomName,
          isGroup: room.isGroup,
          eventId: record.eventId,
          senderId: record.senderId,
          senderName: record.senderName,
          timestamp: record.timestamp,
          body: record.body,
          roomAvatarSeed: room.avatarSeed,
          roomAvatarUrl: room.avatarUrl,
          senderIsSelf: record.senderIsSelf,
        ));
      }
    }
    hits.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final start = offset < 0 ? 0 : offset;
    if (start >= hits.length) return const [];
    final end = start + (limit < 0 ? 0 : limit);
    return hits.sublist(start, end > hits.length ? hits.length : end);
  }

  /// 账号切换/登出：清空本地索引。
  void clear() {
    _rooms.clear();
    _accountEpoch++;
  }

  /// 会话级单例（生产）；测试可注入独立实例。
  static GlobalSearchIndex shared = GlobalSearchIndex();
}

final class _IndexedRoom {
  const _IndexedRoom({
    required this.roomId,
    required this.roomName,
    required this.isGroup,
    required this.records,
    required this.order,
    this.avatarSeed,
    this.avatarUrl,
  });

  final String roomId;
  final String roomName;
  final bool isGroup;
  final Map<String, GlobalSearchMessageRecord> records;
  final SplayTreeMap<_RecordOrder, String> order;
  final String? avatarSeed;
  final String? avatarUrl;
}

// Deterministic ties preserve both events and make oldest eviction logarithmic.
typedef _RecordOrder = (DateTime, String);
int _compareOrder(_RecordOrder a, _RecordOrder b) {
  final time = a.$1.compareTo(b.$1);
  return time != 0 ? time : a.$2.compareTo(b.$2);
}
