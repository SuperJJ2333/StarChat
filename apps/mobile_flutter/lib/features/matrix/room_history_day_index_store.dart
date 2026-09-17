import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'room_history_day_index.dart';

/// 日期索引的轻量持久化（account scoped，仅 metadata）。
///
/// 与 [RoomHistoryDayIndex] 的边界一致：只落盘 日期/anchor/覆盖区间/显式空日，
/// **不落盘任何聊天正文**；账号切换按 accountKey 隔离；schema 版本不匹配
/// 时整体丢弃重建。覆盖以**区间列表**（`coverageRanges`）落盘，不再折叠成
/// 单个 `from`/`to` 跨度，因此两次加载之间的真实空档不会被持久化成“无消息”。
final class RoomHistoryDayIndexStore {
  const RoomHistoryDayIndexStore._();

  static const _keyPrefix = 'room-history-day-index';
  static const _maxRooms = 300;

  static String keyFor(String accountKey) => '$_keyPrefix:$accountKey';

  static Future<RoomHistoryDayIndex> load(String accountKey,
      {SharedPreferences? preferences}) async {
    final prefs = preferences ?? await SharedPreferences.getInstance();
    final raw = prefs.getString(keyFor(accountKey));
    if (raw == null || raw.isEmpty) return RoomHistoryDayIndex();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return RoomHistoryDayIndex();
      return RoomHistoryDayIndex.fromJson(
          decoded.map((key, value) => MapEntry(key.toString(), value)));
    } catch (_) {
      return RoomHistoryDayIndex();
    }
  }

  static Future<void> save(String accountKey, RoomHistoryDayIndex index,
      {SharedPreferences? preferences}) async {
    final prefs = preferences ?? await SharedPreferences.getInstance();
    final json = index.toJson();
    final rooms = json['rooms'];
    if (rooms is Map && rooms.length > _maxRooms) {
      // 只保留最近的 _maxRooms 个房间（metadata 级裁剪）。
      //
      // [RoomHistoryDayIndex.toJson] 按**房间插入顺序**输出 rooms，因此这里从头
      // 删除的是最久未使用的房间；绝不能按 Map 的哈希/任意顺序裁剪。裁剪只丢
      // 整个房间条目，房间内部的 coverageRanges 区间列表原样保留，
      // 不会被压回单个跨度（那会重新制造假的 knownEmpty 空档）。
      final trimmed = Map<String, Object?>.from(rooms);
      while (trimmed.length > _maxRooms) {
        trimmed.remove(trimmed.keys.first);
      }
      json['rooms'] = trimmed;
    }
    await prefs.setString(keyFor(accountKey), jsonEncode(json));
  }

  static Future<void> clear(String accountKey,
      {SharedPreferences? preferences}) async {
    final prefs = preferences ?? await SharedPreferences.getInstance();
    await prefs.remove(keyFor(accountKey));
  }
}
