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

/// device-side 会话内搜索索引（**不落盘、不上传、不含 room key/明文密文**）。
///
/// 设计边界（必须如实告知）：
/// - 只索引「本机已解密的、用户可见的」消息；未解密/被锁定的加密正文永不进入；
/// - 生命周期与账号会话一致（内存）；不建立服务端明文索引；
/// - 数据来源是用户在本会话内打开过的房间时间线（RoomPage 投影），
///   因此它是「本机已知历史」的搜索，而不是「云端全量历史」的搜索。
final class GlobalSearchIndex {
  GlobalSearchIndex({this.maxRooms = 200, this.maxRecordsPerRoom = 4000});

  final int maxRooms;
  final int maxRecordsPerRoom;
  final Map<String, _IndexedRoom> _rooms = <String, _IndexedRoom>{};
  int _accountEpoch = 0;

  /// 当前账号代次（账号切换时索引必须清空，不得跨账号泄漏）。
  @visibleForTesting
  int get accountEpoch => _accountEpoch;

  @visibleForTesting
  int get indexedRoomCount => _rooms.length;

  /// 记录一个房间的本地投影（覆盖式，保留最近 [maxRecordsPerRoom] 条）。
  void recordRoom({
    required String roomId,
    required String roomName,
    required bool isGroup,
    required Iterable<GlobalSearchMessageRecord> messages,
    String? roomAvatarSeed,
    String? roomAvatarUrl,
  }) {
    if (roomId.isEmpty) return;
    final records = messages
        .where((record) =>
            record.eventId.isNotEmpty && record.body.trim().isNotEmpty)
        .toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    _rooms.remove(roomId); // 保持 LRU 顺序
    _rooms[roomId] = _IndexedRoom(
      roomId: roomId,
      roomName: roomName,
      isGroup: isGroup,
      avatarSeed: roomAvatarSeed,
      avatarUrl: roomAvatarUrl,
      records: records.length > maxRecordsPerRoom
          ? records.sublist(0, maxRecordsPerRoom)
          : records,
    );
    while (_rooms.length > maxRooms) {
      _rooms.remove(_rooms.keys.first);
    }
  }

  /// 按关键词检索（连续子串、英文忽略大小写、中文按字），最近优先。
  List<GlobalSearchMessageHit> search(String query, {int limit = 200}) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    final hits = <GlobalSearchMessageHit>[];
    for (final room in _rooms.values) {
      for (final record in room.records) {
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
    return hits.length > limit ? hits.sublist(0, limit) : hits;
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
    this.avatarSeed,
    this.avatarUrl,
  });

  final String roomId;
  final String roomName;
  final bool isGroup;
  final List<GlobalSearchMessageRecord> records;
  final String? avatarSeed;
  final String? avatarUrl;
}
